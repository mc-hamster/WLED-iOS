import XCTest
import Foundation

/// Real app UI coverage. Run separately from the hosted BLE/API suite so only
/// one process owns the peripheral. The app must already be paired/authorized.
/// No network request is made by this UI runner; use the Mac HTTP oracle for
/// independent state verification. Labels below come from the production views.
@MainActor
final class BleUserInterfaceTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment
    private let app = XCUIApplication()
    private var deviceName = "WLED"
    private var originalConnection: String?
    private var originalPower: Bool?
    private var originalBrightness: Int?
    private var originalBrightnessValue: String?
    private var brightnessChanged = false
    private var verifiedIdentity = false
    private var addedBluetooth = false
    private var connectionPreferenceChanged = false

    func testNativeBluetoothControlsAndForegroundReconnect() throws {
        guard environment["BLE_UI_HIL"] == "1" else {
            throw XCTSkip("Physical UI suite requires BLE_UI_HIL=1 and an already-paired fixture")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Bluetooth UI HIL requires a real iPhone")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 600
        deviceName = environment["BLE_UI_DEVICE_NAME"] ?? "WLED"
        if let raw = environment["BLE_UI_BRIGHTNESS"] {
            guard let value = Int(raw), (1...255).contains(value) else {
                throw UIFailure("BLE_UI_BRIGHTNESS must be the exact fixture baseline in 1...255")
            }
            originalBrightness = value
        }
        addTeardownBlock { [weak self] in try await self?.restoreFixture() }
        XCUIDevice.shared.orientation = .portrait
        try launchAtList()

        let existing = app.staticTexts[deviceName]
        if existing.waitForExistence(timeout: 8) {
            guard existing.countMatching(in: app) == 1 else {
                throw UIFailure("Fixture display name is ambiguous; use BLE_UI_DEVICE_NAME")
            }
            existing.tap()
            originalConnection = try inspectIdentityAndConnection()
            if originalConnection == "Wi-Fi" {
                // Add/upsert is the product path that attaches BLE to an
                // existing Wi-Fi record and changes the preferred transport.
                try launchAtList()
                try addBluetoothFixture()
                try openFixtureFromList()
                _ = try inspectIdentityAndConnection()
            } else {
                note("Existing BLE entry reused; Add flow was not rerun because this app may already occupy the peripheral.", name: "Entry path")
            }
        } else {
            try addBluetoothFixture()
            try openFixtureFromList()
            _ = try inspectIdentityAndConnection()
            note("Added fixture through Bluetooth discovery. The saved device entry is retained.", name: "Entry path")
        }

        try waitForNativeConnection()
        if originalConnection == nil {
            originalConnection = try inspectIdentityAndConnection()
        }
        _ = try inspectIdentityAndConnection(selecting: "Wi-Fi")
        guard try inspectIdentityAndConnection() == "Wi-Fi" else {
            throw UIFailure("Wi-Fi preference was not retained after reopening Edit Device")
        }
        _ = try inspectIdentityAndConnection(selecting: "Bluetooth")
        try waitForNativeConnection()
        note("Selected detail changed Bluetooth → Wi-Fi → Bluetooth without app relaunch; reopened Edit Device retained Wi-Fi, and native Bluetooth controls reconnected.", name: "Selected device transport replacement")

        let power = app.switches["Power"]
        originalPower = try powerValue(power)
        try setPower(!(originalPower ?? false))
        try setPower(originalPower ?? false)

        let brightness = app.sliders["Brightness"]
        guard brightness.waitForExistence(timeout: 10), brightness.isEnabled else {
            throw UIFailure("Native Brightness slider is missing or disabled")
        }
        try wait("Native Color control is missing or disabled") {
            [self.app.buttons["Color"], self.app.colorWells["Color"]].contains { $0.exists && $0.isEnabled }
        }
        note("Color control is present/enabled. System color-picker manipulation and color readback are not covered by this test.", name: "Color coverage")

        if let baseline = originalBrightness {
            let target: CGFloat = baseline < 128 ? 0.75 : 0.25
            originalBrightnessValue = try sliderValue(brightness)
            brightnessChanged = true // Cleanup applies even if the gesture/readback fails.
            brightness.adjust(toNormalizedSliderPosition: target)
            try wait("Brightness gesture did not change the slider") {
                (brightness.value as? String) != self.originalBrightnessValue
            }
            let changedValue = try sliderValue(brightness)
            // Keep the client alive until a fresh detail view, initialized
            // from device.stateInfo, confirms the command's readback. Killing
            // the app immediately after the gesture can cancel its BLE write.
            try returnToDeviceList()
            try openFixtureFromList()
            try waitForNativeConnection()
            try wait("Brightness did not reach authoritative device state before relaunch") {
                (self.app.sliders["Brightness"].value as? String) == changedValue
            }
            // A fresh detail view initializes from the newly fetched device
            // state, avoiding a false pass from Slider's local @State alone.
            try launchAtList()
            try openFixtureFromList()
            try waitForNativeConnection()
            try wait("Brightness did not survive a fresh app connection") {
                (self.app.sliders["Brightness"].value as? String) == changedValue
            }
            note("Brightness gesture persisted across app termination/relaunch. UI restoration targets the supplied baseline; XCUI slider gestures have no exact-position guarantee, so the Mac oracle must restore/verify the raw value.", name: "Brightness coverage")
        } else {
            note("Brightness control is present/enabled. Mutation skipped because BLE_UI_BRIGHTNESS was not supplied; exact restoration cannot be inferred from a rounded accessibility percentage.", name: "Brightness coverage")
        }

        XCUIDevice.shared.press(.home)
        try wait("App did not enter a confirmed background state after Home", timeout: 15) {
            let state = self.app.state
            return state == .runningBackground || state == .runningBackgroundSuspended
        }
        // The product deliberately disconnects clients after two background
        // seconds. Start this interval only after background is observed.
        Thread.sleep(forTimeInterval: 4)
        app.activate()
        guard app.wait(for: .runningForeground, timeout: 15) else {
            throw UIFailure("App did not return to foreground")
        }
        try waitForNativeConnection()
        // This control is bound to authoritative BleClient state, not a local
        // toggle cache. A new roundtrip verifies a usable foreground session.
        try setPower(!(originalPower ?? false))
        try setPower(originalPower ?? false)
        note("Native Power roundtrip succeeded before and after Home/background/reactivation. Independent HTTP readback belongs to the Mac oracle.", name: "Foreground lifecycle")
    }

    private func launchAtList() throws {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["BLE_HIL"] = "0"
        app.launch()
        guard app.buttons["Add Device"].waitForExistence(timeout: 20) else {
            throw UIFailure("Device list did not appear; check device unlock and app permissions")
        }
    }

    private func openFixtureFromList() throws {
        let row = app.staticTexts[deviceName]
        guard row.waitForExistence(timeout: 30), row.countMatching(in: app) == 1 else {
            throw UIFailure("Saved fixture display name was missing or ambiguous")
        }
        row.tap()
    }

    private func returnToDeviceList() throws {
        // BackButton is the native navigation identifier observed on the
        // physical phone; Device List is the production sidebar title.
        let matches = app.navigationBars.buttons.matching(
            NSPredicate(format: "identifier == %@ OR label == %@", "BackButton", "Device List")
        )
        try wait("Native back navigation to Device List is unavailable") {
            matches.allElementsBoundByIndex.filter(\.isHittable).count == 1
        }
        let visible = matches.allElementsBoundByIndex.filter(\.isHittable)
        guard visible.count == 1 else { throw UIFailure("Native back navigation is ambiguous") }
        visible[0].tap()
        try wait("Back navigation did not return to Device List") {
            self.app.navigationBars["Device List"].isHittable &&
                self.app.buttons["Add Device"].isHittable &&
                !self.app.switches["Power"].isHittable
        }
    }

    private func addBluetoothFixture() throws {
        app.buttons["Add Device"].tap()
        let bluetooth = app.segmentedControls.buttons["Bluetooth"]
        guard bluetooth.waitForExistence(timeout: 10) else { throw UIFailure("New Device connection picker is missing") }
        bluetooth.tap()
        app.buttons["Select BLE Device"].tap()
        guard app.navigationBars["Nearby WLED"].waitForExistence(timeout: 10) else {
            throw UIFailure("BLE discovery sheet did not open")
        }
        let name = environment["BLE_UI_NAME"] ?? "WLED-db2cb8"
        // The button combines the advertised name and signal text; constrain
        // its prefix and require one visible match rather than choosing a row.
        let pattern = "(?s)^" + NSRegularExpression.escapedPattern(for: name) + "(?:$|[\\s,].*)"
        let matches = app.buttons.matching(NSPredicate(format: "label MATCHES %@", pattern))
        try wait("BLE fixture not advertised; disconnect other centrals and check app Bluetooth permission", timeout: 45) {
            matches.allElementsBoundByIndex.filter(\.isHittable).count == 1
        }
        let visible = matches.allElementsBoundByIndex.filter(\.isHittable)
        guard visible.count == 1 else { throw UIFailure("BLE advertisement name is ambiguous") }
        visible[0].tap()
        let add = app.navigationBars["New Device"].buttons["Add"]
        guard add.waitForExistence(timeout: 10), add.isEnabled else { throw UIFailure("Add did not enable after BLE selection") }
        add.tap()
        let success = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " was added"))
        try wait("Bluetooth Add failed; the fixture must already be bonded and no pairing prompt may remain", timeout: 100) {
            success.count == 1 && self.app.buttons["Done"].exists
        }
        let label = success.element(boundBy: 0).label
        deviceName = String(label.dropLast(" was added".count))
        guard !deviceName.isEmpty else { throw UIFailure("Added device has no display name") }
        addedBluetooth = true
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["Add Device"].waitForExistence(timeout: 10))
    }

    private func inspectIdentityAndConnection(selecting desired: String? = nil) throws -> String {
        let settings = app.navigationBars.buttons["Settings"]
        guard settings.waitForExistence(timeout: 15) else { throw UIFailure("Device Settings navigation is missing") }
        settings.tap()
        guard app.navigationBars["Edit Device"].waitForExistence(timeout: 10) else { throw UIFailure("Edit Device did not open") }
        let mac = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Mac Address: ")).firstMatch
        guard mac.waitForExistence(timeout: 10) else { throw UIFailure("Fixture MAC is not exposed in Edit Device") }
        let expected = environment["BLE_UI_MAC"] ?? "a4cb8fdb2cb8"
        let actual = String(mac.label.dropFirst("Mac Address: ".count))
        guard normalizeMAC(expected).count == 12, normalizeMAC(actual) == normalizeMAC(expected) else {
            throw UIFailure("Selected app device is not the expected fixture")
        }
        verifiedIdentity = true
        let wifi = app.segmentedControls.buttons["Wi-Fi"]
        let bluetooth = app.segmentedControls.buttons["Bluetooth"]
        guard wifi.exists, bluetooth.exists, wifi.isSelected != bluetooth.isSelected else {
            throw UIFailure("Saved connection preference cannot be identified")
        }
        if let desired {
            guard desired == "Wi-Fi" || desired == "Bluetooth" else {
                throw UIFailure("Unknown requested connection preference")
            }
            let choice = desired == "Bluetooth" ? bluetooth : wifi
            guard choice.isEnabled else {
                throw UIFailure("Fixture lacks the \(desired) connection needed for transport replacement coverage")
            }
            if !choice.isSelected {
                connectionPreferenceChanged = true // Cleanup owns a possibly applied preference change.
                choice.tap()
            }
            try wait("Selected connection preference did not update") { choice.isSelected }
        }
        let selected = bluetooth.isSelected ? "Bluetooth" : "Wi-Fi"
        if selected == "Bluetooth" {
            try wait("Edit Device did not show the active Bluetooth connection", timeout: 90) {
                self.app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Status: Connected")).allElementsBoundByIndex.contains { $0.isHittable }
            }
        }
        app.navigationBars["Edit Device"].buttons.element(boundBy: 0).tap()
        return selected
    }

    private func waitForNativeConnection() throws {
        try wait("Native BLE controls did not become connected", timeout: 90) {
            self.app.staticTexts["Connected"].exists && self.app.switches["Power"].exists && self.app.switches["Power"].isEnabled
        }
    }

    private func powerValue(_ element: XCUIElement) throws -> Bool {
        switch (element.value as? String)?.lowercased() {
        case "1", "on": return true
        case "0", "off": return false
        default: throw UIFailure("Power switch did not expose a Boolean accessibility value")
        }
    }

    private func setPower(_ desired: Bool) throws {
        let power = app.switches["Power"]
        guard verifiedIdentity, power.exists, power.isEnabled else { throw UIFailure("Power control is unavailable or identity is unverified") }
        if try powerValue(power) != desired { power.tap() }
        try wait("Power did not update from the BLE response", timeout: 30) {
            (try? self.powerValue(power)) == desired
        }
    }

    private func sliderValue(_ element: XCUIElement) throws -> String {
        guard let value = element.value as? String, !value.isEmpty else { throw UIFailure("Brightness slider has no accessibility value") }
        return value
    }

    private func restoreFixture() throws {
        guard verifiedIdentity,
              originalPower != nil || brightnessChanged || addedBluetooth || connectionPreferenceChanged else { return }
        // Relaunching also closes any discovery/edit sheet left by a failure.
        try launchAtList()
        try openFixtureFromList()
        var failures: [String] = []
        do {
            try waitForNativeConnection()
            if brightnessChanged, let baseline = originalBrightness {
                app.sliders["Brightness"].adjust(toNormalizedSliderPosition: CGFloat(baseline - 1) / 254)
                Thread.sleep(forTimeInterval: 2)
                let achieved = (try? sliderValue(app.sliders["Brightness"])) ?? "unavailable"
                note("Best-effort UI brightness restoration targeted raw value \(baseline); observed slider value: \(achieved). Exact restoration is verified by the Mac HTTP oracle.", name: "Brightness cleanup")
            }
            if let originalPower { try setPower(originalPower) }
        } catch {
            failures.append("Native state restoration could not be verified; use the Mac oracle baseline")
        }
        if let originalConnection {
            do {
                app.navigationBars.buttons["Settings"].tap()
                let choice = app.segmentedControls.buttons[originalConnection]
                guard choice.waitForExistence(timeout: 10), choice.isEnabled else {
                    throw UIFailure("Original preferred connection could not be restored")
                }
                if !choice.isSelected { choice.tap() }
                try wait("Original connection preference was not restored") { choice.isSelected }
                app.navigationBars["Edit Device"].buttons.element(boundBy: 0).tap()
                try launchAtList()
                try openFixtureFromList()
                guard try inspectIdentityAndConnection() == originalConnection else {
                    throw UIFailure("Original connection preference did not persist after relaunch")
                }
            } catch {
                failures.append("Original preferred connection could not be restored")
            }
        }
        guard failures.isEmpty else { throw UIFailure(failures.joined(separator: "; ")) }
        note("Restored captured Power and preferred connection through the UI. Mac oracle must verify exact brightness restoration if that mutation was enabled.", name: "Restoration")
    }

    private func wait(_ message: String, timeout: TimeInterval = 15, condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else { throw UIFailure(message) }
    }

    private func normalizeMAC(_ value: String) -> String { value.lowercased().filter(\.isHexDigit) }

    private func note(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private extension XCUIElement {
    func countMatching(in app: XCUIApplication) -> Int { app.staticTexts.matching(identifier: label).count }
}

private struct UIFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
