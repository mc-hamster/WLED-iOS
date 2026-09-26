import XCTest
import Foundation
import UIKit
import CoreData
@testable import WLED

/// Real iPhone / ESP32 tests. Never run unless the test process explicitly opts in.
@MainActor
final class BleHardwareTests: XCTestCase {
    private let environment = ProcessInfo.processInfo.environment

    func testCommissioningAndCapabilities() async throws {
        try requireHardwareOptIn()
        executionTimeAllowance = 300
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let identifier = try await discoverFixture()
        let session = makeSession(identifier, commissioning: true)
        defer { session.disconnect() }
        // CoreBluetoothTransport reads the protected TX characteristic before subscribing.
        // iOS owns the pairing UI; the code never reads or logs the pairing passkey.
        try await session.connect()
        let info = try await object(session, path: "/json/info")
        try requireIdentity(info)
        guard let ble = info["ble"] as? [String: Any],
              (ble["protocol"] as? NSNumber)?.intValue == 1,
              let limit = (ble["maxRequest"] as? NSNumber)?.intValue, limit >= 256 else {
            throw HardwareFailure("BLE capabilities are missing or incompatible")
        }
        let snapshot = try await object(session, path: "/json")
        guard snapshot["state"] is [String: Any], let repeatedInfo = snapshot["info"] as? [String: Any] else {
            throw HardwareFailure("Initial /json response lacks state/info objects")
        }
        try requireIdentity(repeatedInfo)
        let oracle = try await httpObject(path: "/json")
        guard let oracleInfo = oracle["info"] as? [String: Any] else {
            throw HardwareFailure("HTTP oracle lacks info")
        }
        try requireIdentity(oracleInfo)
        attach("Commissioning passed: production CoreBluetooth transport completed protected TX read, subscriptions, first GET, protocol 1 capabilities, and BLE/HTTP identity match. maxRequest=\(limit).", name: "Commissioning")
    }

    private func requireHardwareOptIn() throws {
        guard environment["BLE_HIL"] == "1" else { throw XCTSkip("Real-device BLE suite requires BLE_HIL=1") }
        #if targetEnvironment(simulator)
        throw XCTSkip("This suite requires a real iPhone with CoreBluetooth")
        #endif
    }

    private func makeSession(_ identifier: UUID, commissioning: Bool = false) -> BleBridgeSession {
        BleBridgeSession(transport: CoreBluetoothTransport(peripheralID: identifier),
                         connectionTimeout: .seconds(commissioning ? 180 : 45), requestTimeout: .seconds(30))
    }

    private func discoverFixture() async throws -> UUID {
        if let value = environment["BLE_HIL_PERIPHERAL_ID"], let identifier = UUID(uuidString: value) {
            return identifier
        }
        let discovery = BleDiscoveryService()
        discovery.startScan()
        defer { discovery.stopScan() }
        let name = environment["BLE_HIL_NAME"] ?? "WLED-db2cb8"
        let deadline = ContinuousClock.now.advanced(by: .seconds(45))
        while ContinuousClock.now < deadline {
            let matches = discovery.peripherals.filter { $0.name == name }
            if matches.count == 1 { return matches[0].id }
            if matches.count > 1 { throw HardwareFailure("Multiple peripherals advertise the fixture name") }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw HardwareFailure("Fixture was not discovered within 45 seconds; check Bluetooth permission and advertising")
    }

    private func requireIdentity(_ info: [String: Any]) throws {
        let expected = (environment["BLE_HIL_MAC"] ?? "a4cb8fdb2cb8").lowercased().filter { $0.isHexDigit }
        let actual = (info["mac"] as? String ?? "").lowercased().filter { $0.isHexDigit }
        guard expected.count == 12, actual == expected else { throw HardwareFailure("Fixture MAC identity mismatch") }
    }

    private func object(_ session: BleBridgeSession, path: String) async throws -> [String: Any] {
        let response = try await session.request(method: "GET", path: path, body: "")
        guard response.status == 200,
              let value = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw HardwareFailure("BLE \(path) did not return a 200 JSON object")
        }
        return value
    }

    private func httpObject(path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let origin = URL(string: environment["BLE_HIL_HTTP_URL"] ?? "http://10.10.41.74"),
              origin.scheme == "http" || origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              let url = URL(string: path, relativeTo: origin)?.absoluteURL else {
            throw HardwareFailure("Invalid fixture HTTP URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HardwareFailure("HTTP \(path) did not return a 200 JSON object")
        }
        return value
    }

    private func attach(_ text: String, name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct HardwareFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

extension BleHardwareTests {
    func testRebootRecovery() async throws {
        try requireHardwareOptIn()
        executionTimeAllowance = 600
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let identifier = try await discoverFixture()
        let run = HardwareAPIRun(identifier: identifier, seed: 0,
                                 makeSession: { self.makeSession(identifier) },
                                 http: { path, body in try await self.httpObject(path: path, body: body) },
                                 identity: { try self.requireIdentity($0) })
        var originalFailure: Error?
        do {
            try await run.scenario("reboot_identity_and_runtime_baseline") { try await run.prepare() }
            try await run.scenario("BleClient_automatic_reconnect_after_verified_reboot") {
                try await run.nativeRebootRecovery { try await self.requestHTTPReset() }
            }
        } catch { originalFailure = error }
        let cleanup = Task { @MainActor in
            try await run.scenario("restore_exact_API_visible_baseline") { try await run.restore() }
        }
        do { try await cleanup.value } catch {
            XCTFail("Reboot baseline restoration failed: \(run.safeDescription(error))")
            if originalFailure == nil { originalFailure = error }
        }
        do { _ = try run.checkConnectionIntegrity() } catch {
            if originalFailure == nil { originalFailure = error }
        }
        run.session.disconnect()
        let data = try JSONSerialization.data(withJSONObject: run.report(soakSeconds: 0), options: [.prettyPrinted, .sortedKeys])
        attach(String(decoding: data, as: UTF8.self), name: "Phase 2 reboot recovery results")
        if let originalFailure { throw HardwareFailure(run.safeDescription(originalFailure)) }
    }

    private func requestHTTPReset() async throws -> String {
        guard let origin = URL(string: environment["BLE_HIL_HTTP_URL"] ?? "http://10.10.41.74"),
              origin.scheme == "http" || origin.scheme == "https", origin.host != nil,
              origin.user == nil, origin.password == nil, origin.query == nil, origin.fragment == nil,
              let url = URL(string: "/reset", relativeTo: origin)?.absoluteURL else {
            throw HardwareFailure("Invalid fixture reset URL")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let client = URLSession(configuration: configuration)
        defer { client.invalidateAndCancel() }
        do {
            let (_, response) = try await client.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw HardwareFailure("HTTP reset was rejected")
            }
            return "HTTP 200"
        } catch let error as URLError where [.networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code) {
            // An interrupted HTTP acknowledgement is accepted only after the caller
            // independently proves this requested boot and an actual BLE disconnect.
            return "HTTP acknowledgement interrupted"
        }
    }

    func testFunctionalAPIAndSoak() async throws {
        try requireHardwareOptIn()
        let duration = Double(environment["BLE_HIL_SOAK_SECONDS"] ?? "600") ?? -1
        guard duration.isFinite, (0...3600).contains(duration) else {
            throw HardwareFailure("BLE_HIL_SOAK_SECONDS must be between 0 and 3600")
        }
        let seed = UInt64(environment["BLE_HIL_SEED"] ?? "20260925") ?? 20260925
        executionTimeAllowance = TimeInterval(Int(duration) + 1200)
        let previousIdleTimer = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        defer { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer }
        let identifier = try await discoverFixture()
        let run = HardwareAPIRun(identifier: identifier, seed: seed,
                                 makeSession: { self.makeSession(identifier) },
                                 http: { path, body in try await self.httpObject(path: path, body: body) },
                                 identity: { try self.requireIdentity($0) })
        var originalFailure: Error?
        do {
            try await run.scenario("identity_capabilities_and_baseline") { try await run.prepare() }
            try await run.scenario("native_BleClient_power_and_brightness") { try await run.nativeControls() }
            try await run.scenario("segment_power_brightness_and_selection") { try await run.segmentControls() }
            try await run.scenario("RGB_RGBW_and_partial_color_formats") { try await run.colorControls() }
            try await run.scenario("effects_palettes_speed_and_intensity") { try await run.effectControls() }
            try await run.scenario("HTTP_to_BLE_LIVE_convergence") { try await run.reverseControls() }
            try await run.scenario("invalid_requests_leave_state_unchanged") { try await run.invalidRequests() }
            try await run.scenario("UTF8_and_maximum_request_boundary") { try await run.requestBoundaries() }
            try await run.scenario("bonded_reconnect_first_command") { try await run.reconnects() }
            try await run.soak(seconds: duration)
            try await run.scenario("connection_integrity") { try run.checkConnectionIntegrity() }
        } catch {
            originalFailure = error
        }
        // Restoration runs even after an ambiguous acknowledgement or failed assertion.
        // A failed scenario is never retried into a pass. Only restoration may reconnect.
        let cleanup = Task { @MainActor in
            try await run.scenario("restore_exact_API_visible_baseline") { try await run.restore() }
        }
        do {
            try await cleanup.value
        } catch {
            XCTFail("Baseline restoration failed: \(run.safeDescription(error))")
            if originalFailure == nil { originalFailure = error }
        }
        do { _ = try run.checkConnectionIntegrity() } catch {
            if originalFailure == nil { originalFailure = error }
        }
        run.session.disconnect()
        let report = run.report(soakSeconds: duration)
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        attach(String(decoding: data, as: UTF8.self), name: "Phase 2 hardware results")
        if let originalFailure { throw HardwareFailure(run.safeDescription(originalFailure)) }
    }
}

/// Uses the production framed session. This class records assertions and restoration state,
/// but contains no alternate Bluetooth implementation or simulated peripheral.
@MainActor
private final class HardwareAPIRun {
    typealias JSON = [String: Any]
    static let segmentFields = ["on", "bri", "col", "fx", "sx", "ix", "pal", "sel", "frz"]
    static let invariantFields = ["start", "stop", "len", "startY", "stopY", "grp", "spc", "of", "n",
                                  "m12", "si", "rev", "mi", "rY", "mY", "tp", "cct", "set",
                                  "c1", "c2", "c3", "o1", "o2", "o3", "bm", "lc"]
    let identifier: UUID
    let seed: UInt64
    var random: UInt64
    var session: BleBridgeSession
    let makeSession: () -> BleBridgeSession
    let http: (String, JSON?) async throws -> JSON
    let identity: (JSON) throws -> Void
    var baseline: JSON?
    var originalState: JSON?
    var target = 0
    var colors: [[Int]] = []
    var effects: [(Int, String)] = []
    var palettes: [(Int, String)] = []
    var maxRequest = 4096
    var mutated = false
    var live: JSON?
    var liveInvalid = false
    var records: [JSON] = []
    var health: [JSON] = []
    var previousUptime: Double?
    var operationCounts: [String: Int] = [:]
    var expectedReboots: [JSON] = []
    var restoreVerified = false
    var httpRestoreVerified = false
    var unexpectedDisconnects = 0
    var disconnectReasons: [String] = []
    var invalidLiveCount = 0
    var restoring = false
    private let started = ContinuousClock.now

    init(identifier: UUID, seed: UInt64, makeSession: @escaping () -> BleBridgeSession,
         http: @escaping (String, JSON?) async throws -> JSON, identity: @escaping (JSON) throws -> Void) {
        self.identifier = identifier
        self.seed = seed
        self.random = seed
        self.makeSession = makeSession
        self.session = makeSession()
        self.http = http
        self.identity = identity
        observeLive()
    }

    func safeDescription(_ error: Error) -> String {
        if let error = error as? HardwareFailure { return error.localizedDescription }
        if error is CancellationError { return "Test was cancelled" }
        if let error = error as? BleBridgeSession.SessionError { return error.localizedDescription }
        // Backend response bodies, configuration and credentials must never enter reports.
        return "\(type(of: error)); external error text omitted"
    }

    func scenario(_ name: String, _ operation: () async throws -> String) async throws {
        let began = ContinuousClock.now
        do {
            let details = try await operation()
            records.append(["name": name, "status": "passed", "seconds": seconds(began.duration(to: .now)), "details": details])
            print("BLE HIL PASS \(name): \(details)")
        } catch {
            records.append(["name": name, "status": "failed", "seconds": seconds(began.duration(to: .now)), "details": safeDescription(error)])
            print("BLE HIL FAIL \(name): \(safeDescription(error))")
            throw error
        }
    }

    func prepare() async throws -> String {
        try await session.connect()
        let snapshot = try await bleObject("/json")
        guard let state = snapshot["state"] as? JSON, let info = snapshot["info"] as? JSON else {
            throw HardwareFailure("BLE /json lacks state/info")
        }
        try identity(info)
        let remote = try await oracle()
        guard let ble = info["ble"] as? JSON, number(ble["protocol"]) == 1,
              let requestLimit = number(ble["maxRequest"]), (256...4096).contains(requestLimit) else {
            throw HardwareFailure("BLE capabilities do not describe protocol 1 and a supported request limit")
        }
        maxRequest = requestLimit
        guard (number(state["ps"]) ?? -1) <= 0, (number(state["pl"]) ?? -1) < 0,
              (state["nl"] as? JSON)?["on"] as? Bool != true, info["live"] as? Bool != true else {
            throw HardwareFailure("Fixture must have no active preset, playlist, nightlight or realtime input")
        }
        guard state["on"] is Bool, state["bri"] is NSNumber,
              let segments = state["seg"] as? [JSON], !segments.isEmpty,
              let udp = state["udpn"] as? JSON, let send = udp["send"] as? Bool else {
            throw HardwareFailure("Fixture lacks restorable segments or runtime UDP send flag")
        }
        var saved: [JSON] = []
        for segment in segments {
            guard let id = number(segment["id"]), Self.segmentFields.allSatisfy({ segment[$0] != nil }) else {
                throw HardwareFailure("A segment lacks required restoration fields")
            }
            var entry: JSON = ["id": id]
            for field in Self.segmentFields { entry[field] = segment[field] }
            saved.append(entry)
        }
        guard let rgb = segments.first(where: { (number($0["lc"]) ?? 0) & 1 != 0 }),
              let id = number(rgb["id"]), let initialColors = rgb["col"] as? [[Int]], initialColors.count == 3,
              initialColors.allSatisfy({ $0.count == 3 || $0.count == 4 }) else {
            throw HardwareFailure("Full functional fixture requires an existing RGB or RGBW segment")
        }
        target = id
        colors = initialColors
        let savedState: JSON = ["on": state["on"]!, "bri": state["bri"]!,
                                "seg": saved, "udpn": ["send": send]]
        let restoreBody = try encode(payload(savedState))
        guard Data("POST /json/state\n\n\(restoreBody)".utf8).count <= maxRequest else {
            throw HardwareFailure("Complete restoration exceeds the advertised request limit")
        }
        originalState = state
        baseline = savedState
        try await verify(savedState)
        let effectNames = try await bleArray("/json/effects")
        let metadata = try await bleArray("/json/fxdata")
        guard effectNames.count == metadata.count, effectNames.count == number(info["fxcount"]) else {
            throw HardwareFailure("Effect names and metadata cannot be mapped to stable IDs")
        }
        effects = effectNames.enumerated().compactMap { index, value in
            guard let name = value as? String, ["Solid", "Blink", "Breathe"].contains(name), metadata[index] is String else { return nil }
            return (index, name)
        }
        if let fixed = remote["palettes"] as? [String] {
            palettes = [0, 2, 6].filter { $0 < fixed.count }.map { ($0, fixed[$0]) }
        }
        guard effects.count >= 2, palettes.count >= 2 else {
            throw HardwareFailure("Fixture requires at least two advertised simple effects and two fixed palettes")
        }
        try sample(info)
        return "Production session and HTTP identify the fixture; saved \(saved.count) segment(s), global controls and runtime UDP flag"
    }

    func nativeControls() async throws -> String {
        // WledState has no per-request udpn.nn. Suppress sync only for this native-client
        // scenario and restore the original runtime flag in the final restoration payload.
        try await apply(["udpn": ["send": false]])
        try await verify(["udpn": ["send": false]])
        session.disconnect()
        try await Task.sleep(for: .milliseconds(700))
        let persistence = PersistenceController(inMemory: true)
        guard let entity = persistence.container.managedObjectModel.entitiesByName["Device"] else {
            throw HardwareFailure("In-memory model lacks Device entity")
        }
        let device = Device(entity: entity, insertInto: persistence.container.viewContext)
        device.macAddress = "fixture"
        device.address = ""
        device.connectionType = "ble"
        device.bleIdentifier = identifier.uuidString
        let observed = ObservedHardwareConnection(session: makeSession())
        let client = BleClient(device: device, session: observed)
        defer { client.destroy() }
        client.connect()
        try await wait(seconds: 50, reason: "Native BleClient did not connect") {
            try self.require(observed.failures == 0, "Native BleClient observed a transport failure")
            return client.deviceState.websocketStatus == .connected && observed.pending == 0
        }
        for (on, brightness) in [(false, 37), (true, 197)] {
            let beforePosts = observed.posts
            client.sendState(WledState(isOn: on, brightness: Int64(brightness)))
            try await wait(seconds: 30, reason: "Native BleClient control/readback did not converge") {
                try self.require(observed.failures == 0, "Native BleClient observed a command failure")
                return observed.posts > beforePosts && observed.pending == 0 &&
                    client.deviceState.stateInfo?.state.isOn == on &&
                    client.deviceState.stateInfo?.state.brightness == Int64(brightness)
            }
            let actual = try await oracle()
            try assertFields(actual["state"] as? JSON ?? [:], expected: ["on": on, "bri": brightness], source: "HTTP/native")
        }
        client.destroy()
        try await Task.sleep(for: .milliseconds(700))
        session = makeSession()
        observeLive()
        try await session.connect()
        try identity(try await bleObject("/json/info"))
        return "Actual BleClient.sendState set power off/on and brightness 37/197; authoritative app state and independent HTTP agreed; no hidden retries"
    }

    func nativeRebootRecovery(reset: () async throws -> String) async throws -> String {
        // The test keeps BleClient alive through link loss. It never invokes its
        // connect method again after reset, so its production retry policy is tested.
        session.disconnect()
        try await Task.sleep(for: .milliseconds(700))
        let persistence = PersistenceController(inMemory: true)
        guard let entity = persistence.container.managedObjectModel.entitiesByName["Device"] else {
            throw HardwareFailure("In-memory model lacks Device entity")
        }
        let device = Device(entity: entity, insertInto: persistence.container.viewContext)
        device.macAddress = "fixture"
        device.address = ""
        device.connectionType = "ble"
        device.bleIdentifier = identifier.uuidString
        let observed = ObservedHardwareConnection(session: makeSession())
        let client = BleClient(device: device, session: observed)
        defer { client.destroy() }
        client.connect()
        try await wait(seconds: 50, reason: "Native BleClient did not connect before reboot") {
            try self.require(observed.failures == 0, "Native BleClient failed before requested reboot")
            return client.deviceState.websocketStatus == .connected && observed.pending == 0
        }
        guard let nativeMAC = client.deviceState.stateInfo?.info.mac else { throw HardwareFailure("Native client lacks identity") }
        try identity(["mac": nativeMAC])
        var before = try await oracle()
        var beforeUptime = ((before["info"] as? JSON)?["uptime"] as? NSNumber)?.doubleValue ?? -1
        try require(beforeUptime >= 0, "Missing pre-reboot uptime")
        if beforeUptime < 20 {
            try await Task.sleep(for: .seconds(20 - beforeUptime))
            before = try await oracle()
            beforeUptime = ((before["info"] as? JSON)?["uptime"] as? NSNumber)?.doubleValue ?? -1
        }
        try require(beforeUptime >= 15, "Pre-reboot uptime is too low to prove rollback")
        try require(client.deviceState.websocketStatus == .connected && observed.failures == 0,
                    "Native link failed before the reset was requested")
        let originalDisconnects = observed.disconnectEvents
        let originalAttempts = observed.connectionAttempts
        let requestedAt = ContinuousClock.now
        mutated = true // Software reboot can replace volatile runtime state, even if its reply is lost.
        let acknowledgement = try await reset()
        try await wait(seconds: 20, reason: "Requested reboot did not disconnect the native BLE client") {
            observed.disconnectEvents > originalDisconnects
        }
        let deadline = requestedAt.advanced(by: .seconds(90))
        var recoveredInfo: JSON?
        var afterUptime = -1.0
        var shift = 0.0
        while ContinuousClock.now < deadline {
            do {
                let snapshot = try await oracle()
                if let info = snapshot["info"] as? JSON, let value = (info["uptime"] as? NSNumber)?.doubleValue {
                    let bootShift = beforeUptime + seconds(requestedAt.duration(to: .now)) - value
                    if value < beforeUptime && bootShift >= 5 {
                        recoveredInfo = info
                        afterUptime = value
                        shift = bootShift
                        break
                    }
                }
            } catch {
                if error is HardwareFailure { throw error }
                try Task.checkCancellation()
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        guard let recoveredInfo else { throw HardwareFailure("Same-device HTTP uptime did not prove the requested reboot") }
        // Only this independently verified, deliberately requested reboot resets the
        // normal no-uptime-rollback invariant used by health sampling and restoration.
        previousUptime = nil
        try sample(recoveredInfo)
        let remaining = Int(ceil(seconds(ContinuousClock.now.duration(to: deadline))))
        try require(remaining > 0, "Native reboot recovery exceeded 90 seconds")
        try await wait(seconds: remaining, reason: "Native BleClient did not automatically reconnect after reboot") {
            observed.connectionAttempts > originalAttempts && client.deviceState.websocketStatus == .connected &&
                observed.pending == 0 && client.deviceState.stateInfo?.info.uptime != nil
        }
        guard let newInfo = client.deviceState.stateInfo?.info, let mac = newInfo.mac, let uptime = newInfo.uptime else {
            throw HardwareFailure("Recovered native state lacks identity or uptime")
        }
        try identity(["mac": mac])
        let elapsed = seconds(requestedAt.duration(to: .now))
        try require(Double(uptime) < beforeUptime && beforeUptime + elapsed - Double(uptime) >= 5,
                    "Native reconnect returned stale pre-reboot state")
        let failuresAfterRecovery = observed.failures
        let postsBefore = observed.posts
        // Native WledState cannot suppress UDP per request; re-disable the runtime
        // flag because reboot may have restored its configured startup value.
        try await apply(["udpn": ["send": false]], viaHTTP: true)
        let quietState = try await oracle()
        try assertFields(quietState["state"] as? JSON ?? [:], expected: ["udpn": ["send": false]], source: "HTTP before native control")
        client.sendState(WledState(isOn: true, brightness: 111))
        try await wait(seconds: 30, reason: "Recovered native client could not apply a state command") {
            try self.require(observed.failures == failuresAfterRecovery, "Native link failed again after reboot recovery")
            return observed.posts > postsBefore && observed.pending == 0 &&
                client.deviceState.stateInfo?.state.isOn == true && client.deviceState.stateInfo?.state.brightness == 111
        }
        let current = try await oracle()
        try assertFields(current["state"] as? JSON ?? [:], expected: ["on": true, "bri": 111, "udpn": ["send": false]], source: "HTTP after reboot")
        expectedReboots.append(["before_uptime_s": beforeUptime, "after_uptime_s": afterUptime,
                                "boot_epoch_shift_s": shift, "native_recovery_s": elapsed,
                                "disconnect_events": observed.disconnectEvents - originalDisconnects,
                                "reconnect_attempts": observed.connectionAttempts - originalAttempts,
                                "reset_acknowledgement": acknowledgement])
        return "HTTP and native uptime prove requested reboot; BleClient automatically reconnected within \(Int(ceil(elapsed)))s, retained bond, and applied brightness 111 verified over HTTP"
    }

    func segmentControls() async throws -> String {
        for update: JSON in [["on": false, "sel": false], ["on": true, "bri": 1], ["bri": 127], ["bri": 255]] {
            try await applySegment(update)
            try await verifySegment(update)
        }
        try await applySegment(["bri": 0, "sel": true])
        try await verifySegment(["on": false, "bri": 255, "sel": true])
        try await applySegment(["on": true])
        try await verifySegment(["on": true])
        return "Existing segment \(target): selection, on/off, brightness 0/1/127/255 and retained opacity verified over BLE and HTTP"
    }

    func colorControls() async throws -> String {
        let width = colors[0].count
        colors = [[11, 47, 89], [131, 173, 211], [29, 71, 113]]
        if width == 4 {
            for index in colors.indices { colors[index].append([23, 53, 83][index]) }
        }
        try await applySegment(["col": colors])
        try await verifySegment(["col": colors])
        try await applySegment(["col": [["g": 101], [], []] as [Any]])
        colors[0][1] = 101
        try await verifySegment(["col": colors])
        try await applySegment(["col": ["336699", [], []] as [Any]])
        colors[0] = [51, 102, 153] + (width == 4 ? [0] : [])
        try await verifySegment(["col": colors])
        return "Three color slots, partial green-channel update, empty-slot preservation and six-digit hex; \(width)-channel fixture"
    }

    func effectControls() async throws -> String {
        for (id, _) in effects {
            let previous = try segment(try await bleObject("/json/state"))
            var expected = try requiredHardwareFields(previous, ["sx", "ix", "pal"], source: "effect readback")
            expected["fx"] = id
            try await applySegment(["fx": id])
            try await verifySegment(expected)
        }
        for (speed, intensity) in [(0, 255), (1, 254), (127, 128), (255, 0)] {
            try await applySegment(["sx": speed, "ix": intensity])
            try await verifySegment(["sx": speed, "ix": intensity])
        }
        for (id, _) in palettes {
            try await applySegment(["pal": id])
            try await verifySegment(["pal": id])
        }
        return "Effects \(effects.map { $0.1 }.joined(separator: ", ")); fixed palettes \(palettes.map { $0.1 }.joined(separator: ", ")); speed/intensity byte boundaries verified"
    }

    func reverseControls() async throws -> String {
        let previous = try segment(try await bleObject("/json/state"))
        let speed = ((number(previous["sx"]) ?? 0) + 37) % 256
        let update: JSON = ["on": true, "bri": 83, "sx": speed, "ix": 219, "fx": effects[0].0, "pal": palettes.last!.0]
        live = nil
        try await apply(["seg": [( ["id": target] as JSON).merging(update) { _, value in value }]], viaHTTP: true)
        try await verifySegment(update)
        try await wait(seconds: 15, reason: "LIVE did not converge after HTTP mutation") {
            try self.require(!self.liveInvalid, "Invalid LIVE payload or identity")
            guard let latest = self.live, let state = latest["state"] as? JSON,
                  let value = try? self.segment(state) else { return false }
            return update.allSatisfy { self.equal(value[$0.key], $0.value) }
        }
        return "HTTP effect/palette/speed/intensity/power/brightness mutation matched BLE readback and production LIVE assembly"
    }

    func invalidRequests() async throws -> String {
        let before = try await bleObject("/json/state")
        for (method, path, body, status) in [("POST", "/json/state", "{", 400),
                                          ("POST", "/json/state", "[]", 400),
                                          ("POST", "/json/state", "null", 400),
                                          ("POST", "/unsupported", "{}", 404),
                                          ("DELETE", "/json/state", "", 405)] {
            let response = try await request(method: method, path: path, body: body)
            try require(response.status == status, "Unexpected API error status for \(method) \(path)")
            try await verify(try hardwareStateProjection(before))
        }
        return "400 malformed/non-object JSON, 404 unsupported route and 405 method; both transports prove state unchanged"
    }

    func requestBoundaries() async throws -> String {
        let path = "/json/info" + String(repeating: " ", count: maxRequest - Data("GET /json/info\n\n".utf8).count)
        let response = try await request(method: "GET", path: path)
        try require(response.status == 200, "Advertised maximum-size request was rejected")
        guard let value = try JSONSerialization.jsonObject(with: response.body) as? JSON else { throw HardwareFailure("Maximum-size response is invalid") }
        try identity(value)
        let unicodeBody = try encode(["v": true, "_hil": String(repeating: "é😀", count: 60)])
        let unicode = try await request(method: "POST", path: "/json/state", body: unicodeBody)
        try require(unicode.status == 200, "UTF-8 request failed")
        return "Exact \(maxRequest)-byte application request and fragmented multibyte UTF-8 round trip; ATT size is selected by production transport"
    }

    func reconnects() async throws -> String {
        for _ in 0..<5 { try await reconnect() }
        return "Five fresh production sessions; each first command returned /json/info with the expected MAC"
    }

    func reconnect() async throws {
        session.disconnect()
        try await Task.sleep(for: .milliseconds(700))
        session = makeSession()
        observeLive()
        try await session.connect()
        let info = try await bleObject("/json/info")
        try identity(info)
        try sample(info)
    }

    func soak(seconds duration: Double) async throws {
        if duration == 0 { return }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(Int64(duration * 1000)))
        var cycle = 0
        let names = ["brightness_readback", "effect_parameters", "reconnect_first_read", "HTTP_to_LIVE", "effects_read"]
        while ContinuousClock.now < deadline && cycle < 2000 {
            try Task.checkCancellation()
            random = random &* 6364136223846793005 &+ 1442695040888963407
            let operation = Int((random >> 32) % 5)
            let name = names[operation]
            try await scenario("soak_\(cycle)_\(name)") {
                switch operation {
                case 0:
                    let brightness = 1 + Int((self.random >> 40) % 255)
                    try await self.apply(["on": true, "bri": brightness])
                    try await self.verify(["on": true, "bri": brightness])
                case 1:
                    let values: JSON = ["sx": Int((self.random >> 24) & 255), "ix": Int((self.random >> 16) & 255)]
                    try await self.applySegment(values)
                    try await self.verifySegment(values)
                case 2: try await self.reconnect()
                case 3: _ = try await self.reverseControls()
                default: try self.require(!(try await self.bleArray("/json/effects")).isEmpty, "Effects became empty")
                }
                let info = try await self.bleObject("/json/info")
                try self.identity(info)
                try self.sample(info)
                self.operationCounts[name, default: 0] += 1
                return "\(name) and uptime/heap sample verified"
            }
            cycle += 1
        }
        try require(cycle < 2000 || ContinuousClock.now >= deadline, "Soak cycle cap reached before requested duration")
    }

    func restore() async throws -> String {
        guard let baseline, mutated else { return "No state mutation requires restoration" }
        restoring = true
        defer { restoring = false }
        // A separate session eliminates any in-flight request from a failed native client.
        session.disconnect()
        try await Task.sleep(for: .milliseconds(700))
        session = makeSession()
        observeLive()
        do {
            try await session.connect()
            try identity(try await bleObject("/json/info"))
            _ = try await oracle()
            try await apply(baseline)
            try await verify(baseline)
            try sample(try await bleObject("/json/info"))
            restoreVerified = true
            httpRestoreVerified = true
            return "Global power/brightness, every touched segment field (including all freeze flags), and runtime UDP send flag restored; BLE and HTTP verified"
        } catch {
            let bleFailure = safeDescription(error)
            session.disconnect()
            _ = try await oracle()
            _ = try await http("/json/state", payload(baseline))
            let restored = try await oracle()
            try assertFields(restored["state"] as? JSON ?? [:], expected: baseline, source: "HTTP restoration")
            httpRestoreVerified = true
            throw HardwareFailure("HTTP restored and verified baseline, but BLE restoration verification failed: \(bleFailure)")
        }
    }

    func checkConnectionIntegrity() throws -> String {
        try require(unexpectedDisconnects == 0, "Production session observed an unexpected disconnect")
        try require(invalidLiveCount == 0, "Production session received invalid LIVE data")
        return "No unexpected production-session disconnect or invalid LIVE payload was hidden by reconnection"
    }

    private func observeLive() {
        live = nil
        liveInvalid = false
        session.onLivePayload = { [weak self] data in
            guard let self else { return }
            do {
                guard let value = try JSONSerialization.jsonObject(with: data) as? JSON,
                      value["state"] is JSON, let info = value["info"] as? JSON else { throw HardwareFailure("Malformed LIVE") }
                try self.identity(info)
                self.live = value
            } catch {
                self.liveInvalid = true
                self.invalidLiveCount += 1
                print("BLE HIL INVALID LIVE: \(self.safeDescription(error))")
            }
        }
        session.onDisconnect = { [weak self] error in
            guard let self else { return }
            self.unexpectedDisconnects += 1
            let reason: String
            if let known = error as? BleBridgeSession.SessionError {
                reason = known.localizedDescription
            } else {
                let value = error as NSError
                reason = "\(value.domain) code \(value.code)"
            }
            self.disconnectReasons.append(reason)
            print("BLE HIL UNEXPECTED DISCONNECT: \(reason)")
        }
    }

    private func request(method: String, path: String, body: String = "") async throws -> BleBridgeResponse {
        if !restoring {
            try require(unexpectedDisconnects == 0, "Unexpected disconnect occurred before the next operation")
            try require(invalidLiveCount == 0, "Invalid LIVE payload occurred before the next operation")
        }
        let current = session
        var expired = false
        let deadline = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            expired = true
            current.disconnect()
        }
        defer { deadline.cancel() }
        do {
            let result = try await current.request(method: method, path: path, body: body)
            try require(!expired, "BLE operation exceeded its absolute 45-second deadline")
            return result
        } catch {
            if expired { throw HardwareFailure("BLE operation exceeded its absolute 45-second deadline") }
            throw error
        }
    }

    private func bleObject(_ path: String) async throws -> JSON {
        let response = try await request(method: "GET", path: path)
        guard response.status == 200, let value = try JSONSerialization.jsonObject(with: response.body) as? JSON else {
            throw HardwareFailure("BLE \(path) did not return a 200 object")
        }
        return value
    }

    private func bleArray(_ path: String) async throws -> [Any] {
        let response = try await request(method: "GET", path: path)
        guard response.status == 200, let value = try JSONSerialization.jsonObject(with: response.body) as? [Any] else {
            throw HardwareFailure("BLE \(path) did not return a 200 array")
        }
        return value
    }

    private func oracle() async throws -> JSON {
        let value = try await http("/json", nil)
        guard let info = value["info"] as? JSON, value["state"] is JSON else { throw HardwareFailure("HTTP lacks state/info") }
        try identity(info)
        return value
    }

    private func payload(_ update: JSON) -> JSON {
        var result = update
        result["tt"] = 0
        var udp = result["udpn"] as? JSON ?? [:]
        udp["nn"] = true
        result["udpn"] = udp
        if var segments = result["seg"] as? [JSON] {
            for index in segments.indices where segments[index]["fx"] != nil { segments[index]["fxdef"] = false }
            result["seg"] = segments
        }
        return result
    }

    private func apply(_ update: JSON, viaHTTP: Bool = false) async throws {
        mutated = true
        let value = payload(update)
        if viaHTTP {
            _ = try await oracle() // Verify HTTP identity immediately before a write.
            _ = try await http("/json/state", value)
        } else {
            let response = try await request(method: "POST", path: "/json/state", body: encode(value))
            try require(response.status == 200, "State mutation was rejected")
        }
    }

    private func applySegment(_ update: JSON) async throws {
        try await apply(["seg": [( ["id": target] as JSON).merging(update) { _, value in value }]])
    }

    private func verifySegment(_ expected: JSON) async throws {
        try await verify(["seg": [( ["id": target] as JSON).merging(expected) { _, value in value }]])
    }

    private func verify(_ expected: JSON) async throws {
        let ble = try await bleObject("/json/state")
        let remote = try await oracle()
        try assertFields(ble, expected: expected, source: "BLE")
        try assertFields(remote["state"] as? JSON ?? [:], expected: expected, source: "HTTP")
    }

    private func assertFields(_ state: JSON, expected: JSON, source: String) throws {
        for key in ["on", "bri"] where expected[key] != nil {
            try require(equal(state[key], expected[key]), "\(source): global \(key) mismatch")
        }
        if let udp = expected["udpn"] as? JSON {
            try require(equal((state["udpn"] as? JSON)?["send"], udp["send"]), "\(source): runtime UDP send flag mismatch")
        }
        for segment in expected["seg"] as? [JSON] ?? [] {
            guard let found = (state["seg"] as? [JSON])?.first(where: { equal($0["id"], segment["id"]) }) else {
                throw HardwareFailure("\(source): expected segment is missing")
            }
            for (key, value) in segment { try require(equal(found[key], value), "\(source): segment field \(key) mismatch") }
        }
        if let originalState {
            try require(equal(state["mainseg"], originalState["mainseg"]), "\(source): main segment changed")
            let current = state["seg"] as? [JSON] ?? []
            let original = originalState["seg"] as? [JSON] ?? []
            try require(current.count == original.count, "\(source): segment count changed")
            for (before, after) in zip(original, current) {
                for key in ["id"] + Self.invariantFields {
                    try require(equal(before[key], after[key]), "\(source): segment invariant \(key) changed")
                }
            }
        }
    }

    private func segment(_ state: JSON) throws -> JSON {
        guard let value = (state["seg"] as? [JSON])?.first(where: { number($0["id"]) == target }) else {
            throw HardwareFailure("Target segment missing")
        }
        return value
    }

    private func sample(_ info: JSON) throws {
        guard let uptime = (info["uptime"] as? NSNumber)?.doubleValue else { throw HardwareFailure("Missing uptime sample") }
        if let previousUptime { try require(uptime >= previousUptime, "Unexpected firmware uptime rollback") }
        previousUptime = uptime
        var value: JSON = ["elapsed_s": seconds(started.duration(to: .now)), "uptime_s": uptime]
        for key in ["freeheap", "maxalloc", "minfreeheap"] where info[key] is NSNumber { value[key] = info[key] }
        health.append(value)
    }

    private func wait(seconds duration: Int, reason: String, _ condition: () throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(duration))
        while ContinuousClock.now < deadline {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw HardwareFailure(reason)
    }

    private func encode(_ value: JSON) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self) }
    private func number(_ value: Any?) -> Int? { (value as? NSNumber)?.intValue }
    private func equal(_ a: Any?, _ b: Any?) -> Bool {
        if a == nil && b == nil { return true }
        guard let a = a as? NSObject, let b = b as? NSObject else { return false }
        return a.isEqual(b)
    }
    private func require(_ value: Bool, _ message: String) throws { if !value { throw HardwareFailure(message) } }
    private func seconds(_ value: Duration) -> Double { Double(value.components.seconds) + Double(value.components.attoseconds) / 1e18 }

    func report(soakSeconds: Double) -> JSON {
        let heap = health.compactMap { ($0["freeheap"] as? NSNumber)?.doubleValue }
        var heapSummary: JSON = ["samples": heap.count]
        if let first = heap.first, let last = heap.last, let minimum = heap.min(), let maximum = heap.max() {
            let tail = Array(heap.suffix(max(1, heap.count / 4)))
            heapSummary.merge(["first": first, "last": last, "minimum": minimum, "maximum": maximum,
                               "final_quarter_minimum": tail.min()!, "final_quarter_maximum": tail.max()!]) { _, value in value }
        }
        return ["schema": 1, "platform": "real iPhone", "seed": String(seed), "soak_requested_s": soakSeconds,
                "duration_s": seconds(started.duration(to: .now)), "cases": records, "soak_operation_counts": operationCounts,
                "verified_requested_reboots": expectedReboots,
                "health_samples": health, "freeheap_summary": heapSummary, "baseline_restored": restoreVerified,
                "baseline_HTTP_restored": httpRestoreVerified, "unexpected_disconnects": unexpectedDisconnects, "invalid_live_payloads": invalidLiveCount,
                "disconnect_reasons": disconnectReasons,
                "outcome": records.contains { $0["status"] as? String == "failed" } || unexpectedDisconnects > 0 || invalidLiveCount > 0 ? "failed" : "passed_selected_coverage",
                "excluded": ["background/locked iPhone operation", "bond deletion and passkey rotation", "radio interference/range",
                             "hardware power cycling", "preset/configuration persistence", "physical LED output", "effect animation phase restoration"]]
    }
}

/// A malformed device reply must throw into normal restoration, never trap on an
/// absent dictionary key and terminate the XCTest host before cleanup can run.
private func requiredHardwareFields(_ object: [String: Any], _ fields: [String], source: String) throws -> [String: Any] {
    var result: [String: Any] = [:]
    for field in fields {
        guard let value = object[field] else { throw HardwareFailure("\(source): missing required field \(field)") }
        result[field] = value
    }
    return result
}

@MainActor
private func hardwareStateProjection(_ state: [String: Any]) throws -> [String: Any] {
    var result = try requiredHardwareFields(state, ["on", "bri"], source: "state readback")
    guard let segments = state["seg"] as? [[String: Any]] else { throw HardwareFailure("State readback lacks segment array") }
    result["seg"] = try segments.map {
        try requiredHardwareFields($0, ["id"] + HardwareAPIRun.segmentFields, source: "segment readback")
    }
    return result
}

@MainActor
final class BleHardwareValidationTests: XCTestCase {
    func testMissingResponseFieldsThrowInsteadOfTrapping() {
        XCTAssertThrowsError(try hardwareStateProjection(["bri": 42, "seg": []]))
        XCTAssertThrowsError(try hardwareStateProjection(["on": true, "seg": []]))
        XCTAssertThrowsError(try hardwareStateProjection(["on": true, "bri": 42]))
        XCTAssertThrowsError(try hardwareStateProjection(["on": true, "bri": 42, "seg": [["id": 0]]]))
        XCTAssertThrowsError(try requiredHardwareFields(["sx": 42, "ix": 80], ["sx", "ix", "pal"], source: "effect readback"))
    }

    func testProjectionPreservesExplicitFalseAndZero() throws {
        let segment: [String: Any] = ["id": 0, "on": false, "bri": 1, "col": [[0, 0, 0], [0, 0, 0], [0, 0, 0]],
                                      "fx": 0, "sx": 0, "ix": 0, "pal": 0, "sel": false, "frz": true]
        let state: [String: Any] = ["on": false, "bri": 1, "seg": [segment]]
        XCTAssertEqual(try hardwareStateProjection(state) as NSDictionary, state as NSDictionary)
    }
}

/// A transparent recorder exposes errors that BleClient would otherwise retry automatically.
/// All transport and protocol work is performed by the injected production session.
@MainActor
private final class ObservedHardwareConnection: BleBridgeConnection {
    var onLivePayload: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    let session: BleBridgeSession
    var failures = 0
    var pending = 0
    var posts = 0
    var connectionAttempts = 0
    var disconnectEvents = 0
    init(session: BleBridgeSession) {
        self.session = session
        session.onLivePayload = { [weak self] data in self?.onLivePayload?(data) }
        session.onDisconnect = { [weak self] error in
            self?.failures += 1
            self?.disconnectEvents += 1
            self?.onDisconnect?(error)
        }
    }
    func connect() async throws {
        connectionAttempts += 1
        do { try await session.connect() } catch { failures += 1; throw error }
    }
    func disconnect() { session.disconnect() }
    func request(method: String, path: String, body: String) async throws -> BleBridgeResponse {
        pending += 1
        defer { pending -= 1 }
        do {
            let response = try await session.request(method: method, path: path, body: body)
            if method == "POST" { posts += 1 }
            return response
        } catch { failures += 1; throw error }
    }
}
