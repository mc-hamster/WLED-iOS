import XCTest

/// Deterministic interface checks. This fixture does not connect to a saved device or use a radio.
@MainActor
final class StudioInterfaceTests: XCTestCase {
    private let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The studio design fixture is available only in Simulator")
        #endif
        executionTimeAllowance = 120
        app.launchEnvironment["WLED_STUDIO_PREVIEW"] = "1"
        app.launchEnvironment["BLE_HIL"] = "0"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
    }

    func testLightEffectsScenesAndConfirmedEffectSelection() throws {
        app.launch()
        XCTAssertTrue(app.switches["Power"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.sliders["Brightness"].exists)
        XCTAssertTrue(app.staticTexts["Breathe"].waitForExistence(timeout: 10))
        capture("Studio · Light")

        try reveal(app.segmentedControls.buttons["Effects"])
        app.segmentedControls.buttons["Effects"].tap()
        let effectPicker = app.buttons["studio-effect-picker"]
        try reveal(effectPicker)
        capture("Studio · Effects")
        effectPicker.tap()
        let aurora = app.buttons["studio-catalog-effect-2"]
        XCTAssertTrue(aurora.waitForExistence(timeout: 10))
        aurora.tap()
        XCTAssertTrue(effectPicker.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Aurora"].firstMatch.waitForExistence(timeout: 10))

        // Reopen the catalog: its selected trait is sourced from a fresh device /json response.
        try reveal(effectPicker)
        effectPicker.tap()
        XCTAssertTrue(aurora.waitForExistence(timeout: 10))
        XCTAssertTrue(aurora.isSelected, "The selected effect should match confirmed device state")
        app.navigationBars["Effects"].buttons["Done"].tap()

        try reveal(app.segmentedControls.buttons["Scenes"], direction: .down)
        app.segmentedControls.buttons["Scenes"].tap()
        XCTAssertTrue(app.buttons["studio-scene-1"].waitForExistence(timeout: 10))
        try reveal(app.buttons["studio-scene-1"])
        capture("Studio · Scenes")
    }

    func testPalettePreviewAndSelection() throws {
        app.launch()
        XCTAssertTrue(app.switches["Power"].waitForExistence(timeout: 15))
        try reveal(app.segmentedControls.buttons["Effects"])
        app.segmentedControls.buttons["Effects"].tap()
        let palettePicker = app.buttons["studio-palette-picker"]
        try reveal(palettePicker)
        palettePicker.tap()
        let ocean = app.buttons["studio-catalog-palette-2"]
        XCTAssertTrue(ocean.waitForExistence(timeout: 10))
        capture("Studio · Palette library")
        ocean.tap()
        XCTAssertTrue(palettePicker.waitForExistence(timeout: 10))
        try reveal(palettePicker)
        palettePicker.tap()
        XCTAssertTrue(ocean.waitForExistence(timeout: 10))
        XCTAssertTrue(ocean.isSelected)
    }

    func testAdvancedWorkspaceLoadsOfflineResourcesAndCatalogs() throws {
        app.launch()
        XCTAssertTrue(app.switches["Power"].waitForExistence(timeout: 15))
        let advanced = app.buttons["studio-advanced-controls"]
        try reveal(advanced)
        advanced.tap()
        XCTAssertTrue(app.navigationBars.buttons["Workspace destinations"].waitForExistence(timeout: 15))
        app.navigationBars.buttons["Workspace destinations"].tap()
        app.buttons["Device settings"].tap()
        let workspace = app.webViews.firstMatch
        XCTAssertTrue(workspace.waitForExistence(timeout: 15))
        XCTAssertTrue(workspace.buttons["LED & Hardware"].waitForExistence(timeout: 15))
        capture("Studio · Offline advanced settings")
        app.navigationBars.buttons["Workspace destinations"].tap()
        app.buttons["All controls"].tap()
        let effectsTab = workspace.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Effects")).firstMatch
        XCTAssertTrue(effectsTab.waitForExistence(timeout: 15))
        effectsTab.tap()
        XCTAssertTrue(workspace.staticTexts["Aurora"].firstMatch.waitForExistence(timeout: 15),
                      "The offline HTML should load effect catalogs through the native bridge")
        capture("Studio · Offline full controls")
    }

    func testAccessibilitySizeKeepsPrimaryControlsReachable() throws {
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.switches["Power"].waitForExistence(timeout: 15))
        capture("Studio · Accessibility XXXL · Light")
        try reveal(app.sliders["Brightness"])
        XCTAssertTrue(app.sliders["Brightness"].isEnabled)
        try reveal(app.segmentedControls.buttons["Effects"], direction: .down)
        app.segmentedControls.buttons["Effects"].tap()
        try reveal(app.buttons["studio-effect-picker"])
        capture("Studio · Accessibility XXXL · Effects")
        app.buttons["studio-effect-picker"].tap()
        XCTAssertTrue(app.buttons["studio-catalog-effect-2"].waitForExistence(timeout: 10))
        capture("Studio · Accessibility XXXL · Catalog")
    }

    private enum Direction { case up, down }

    private func reveal(_ element: XCUIElement, direction: Direction = .up) throws {
        guard element.waitForExistence(timeout: 10) else { throw InterfaceError("Expected control is missing: \(element.identifier)") }
        for _ in 0..<8 {
            if element.isHittable { return }
            if direction == .up { app.swipeUp() } else { app.swipeDown() }
        }
        guard element.isHittable else { throw InterfaceError("Control cannot be reached by scrolling: \(element.identifier)") }
    }

    private func capture(_ title: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = title
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct InterfaceError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
