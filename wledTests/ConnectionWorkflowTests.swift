import XCTest
import CoreData
@testable import WLED

@MainActor
final class ConnectionWorkflowTests: XCTestCase {
    private func fixture(mode: DeviceConnectionMode = .automatic) -> (PersistenceController, Device, UserDefaults) {
        let persistence = PersistenceController(inMemory: true)
        let device = Device(context: persistence.container.viewContext)
        device.macAddress = UUID().uuidString
        device.address = "192.0.2.1"
        device.bleIdentifier = UUID().uuidString
        device.connectionMode = mode
        let defaults = UserDefaults(suiteName: "ConnectionTests.\(UUID())")!
        return (persistence, device, defaults)
    }

    func testAutomaticFallbackHasOneRouteAndNoWriteReplay() async throws {
        let (persistence, device, defaults) = fixture()
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        defer { controller.destroy() }
        controller.connectByUser()
        XCTAssertEqual(clients.map(\.route), [.wifi])
        clients[0].ready()
        try await settle { controller.deviceState.isOnline }
        controller.sendState(WledState(brightness: 37))
        clients[0].fail()
        try await settle { clients.count == 2 }
        XCTAssertTrue(clients[0].destroyed)
        XCTAssertEqual(clients[1].route, .ble)
        XCTAssertTrue(clients[1].sent.isEmpty)
        clients[1].ready()
        try await settle { controller.deviceState.activeTransport == .ble }
        XCTAssertTrue(controller.deviceState.connectionSummary.contains("Bluetooth"))
        clients[0].ready() // Late callback from retired transport cannot take over.
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(controller.deviceState.activeTransport, .ble)
        XCTAssertNotNil(controller.deviceState.recoveryMessage)
    }

    func testManualModesNeverFallback() async throws {
        for mode in [DeviceConnectionMode.wifi, .ble] {
            let (persistence, device, defaults) = fixture(mode: mode)
            defer { _ = persistence }
            var clients: [WorkflowClient] = []
            let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
                let client = WorkflowClient(device: device, route: route); clients.append(client); return client
            }
            controller.connectByUser()
            clients[0].fail(requiresAction: true)
            try await settle { controller.deviceState.connectionError != nil }
            XCTAssertEqual(clients.count, 1)
            XCTAssertEqual(clients[0].route.rawValue, mode.rawValue)
            controller.destroy()
        }
    }

    func testManualDisconnectSurvivesRefreshResumeReconfigureAndNewController() async throws {
        let (persistence, device, defaults) = fixture(mode: .ble)
        defer { _ = persistence }
        var count = 0
        let factory: (Device, DeviceConnectionType) -> any DeviceConnectionClient = { device, route in
            count += 1; return WorkflowClient(device: device, route: route)
        }
        let first = DeviceConnectionController(device: device, defaults: defaults, factory: factory)
        first.connectByUser()
        first.disconnectByUser()
        first.connect()
        device.connectionMode = .wifi
        first.reconfigure()
        first.disconnect(); first.connect()
        first.sendState(WledState(isOn: false))
        XCTAssertEqual(count, 1)
        XCTAssertTrue(first.deviceState.manuallyDisconnected)
        XCTAssertTrue(first.deviceState.commandMessage?.hasPrefix("Not sent") == true)
        first.destroy()
        let restored = DeviceConnectionController(device: device, defaults: defaults, factory: factory)
        restored.connect(); restored.deviceState.openAction()
        XCTAssertEqual(count, 1)
        restored.connectByUser()
        XCTAssertEqual(count, 2)
        restored.destroy()
    }

    func testListDoesNotClaimUnusedBLEAndHiddenDevices() {
        for hidden in [false, true] {
            let (persistence, device, defaults) = fixture(mode: .ble)
            defer { _ = persistence }
            device.isHidden = hidden
            var count = 0
            let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
                count += 1; return WorkflowClient(device: device, route: route)
            }
            controller.connect()
            XCTAssertEqual(count, 0)
            controller.deviceState.openAction()
            XCTAssertEqual(count, 1)
            controller.destroy()
        }
    }

    func testSavedBluetoothDisableStopsAutomaticFallbackAndPersistsDisconnect() async throws {
        let (persistence, device, defaults) = fixture()
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let factory: (Device, DeviceConnectionType) -> any DeviceConnectionClient = { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        let controller = DeviceConnectionController(device: device, defaults: defaults, factory: factory)
        controller.retryDelay = .milliseconds(10)
        controller.connectByUser()
        clients[0].fail()
        try await settle { clients.count == 2 }
        clients[1].ready()
        try await settle { controller.deviceState.activeTransport == .ble }
        controller.deviceState.bluetoothDisabledAction()
        XCTAssertTrue(controller.deviceState.manuallyDisconnected)
        XCTAssertFalse(controller.deviceState.isOnline)
        XCTAssertTrue(clients[1].destroyed)
        XCTAssertTrue(controller.deviceState.recoveryMessage?.contains("turned off") == true)
        clients[1].fail() // The deliberate radio shutdown may deliver a late callback.
        controller.connect()
        controller.deviceState.openAction()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clients.count, 2)
        controller.destroy()
        let restored = DeviceConnectionController(device: device, defaults: defaults, factory: factory)
        restored.connect()
        restored.deviceState.openAction()
        XCTAssertEqual(clients.count, 2)
        restored.connectByUser()
        XCTAssertEqual(clients.count, 3)
        restored.destroy()
    }

    func testDisablingBluetoothWhileUsingWiFiKeepsItsConnection() async throws {
        let (persistence, device, defaults) = fixture(mode: .wifi)
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        defer { controller.destroy() }
        controller.connectByUser()
        clients[0].ready()
        try await settle { controller.deviceState.isOnline }
        controller.deviceState.bluetoothDisabledAction()
        XCTAssertTrue(controller.deviceState.isOnline)
        XCTAssertFalse(controller.deviceState.manuallyDisconnected)
        XCTAssertFalse(clients[0].destroyed)
    }

    func testRetriesAreBoundedAndDisconnectCancelsRetry() async throws {
        let (persistence, device, defaults) = fixture(mode: .wifi)
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        controller.retryDelay = .milliseconds(10)
        controller.connectByUser()
        for index in 0..<3 {
            try await settle { clients.count == index + 1 }
            clients[index].fail()
        }
        try await settle { controller.deviceState.recoveryMessage?.contains("stopped") == true }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clients.count, 3)
        controller.connectByUser()
        clients.last?.fail()
        controller.disconnectByUser()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(clients.count, 4)
        controller.destroy()
    }

    func testEditingAddressIsDraftAndNormalizesOnlyValidEndpoints() async throws {
        let (persistence, device, _) = fixture(mode: .wifi)
        let editor = DeviceEditViewModel(device: DeviceWithState(initialDevice: device), context: persistence.container.viewContext)
        editor.wifiAddress = "wrong.partial"
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(device.address, "192.0.2.1")
        XCTAssertEqual(try validatedDeviceAddress(" http://wled.local:81/ "), "wled.local:81")
        XCTAssertEqual(try validatedDeviceAddress("10.10.41.74"), "10.10.41.74")
        for address in ["", "https://wled.local", "http://", "wled.local/settings", "user:secret@wled.local", "wled.local?foo=bar"] {
            XCTAssertThrowsError(try validatedDeviceAddress(address), address)
        }
        device.address = ""
        XCTAssertEqual(device.preferredConnectionType, .wifi, "Manual mode must not silently resolve to BLE")
    }

    func testRawRequestUsesSelectedRouteAndPreservesStatusAndData() async throws {
        let (persistence, device, defaults) = fixture(mode: .ble)
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        defer { controller.destroy() }
        controller.connectByUser()
        clients[0].ready()
        try await settle { controller.deviceState.isOnline }
        let payload = Data("{\"name\":\"Evening\"}".utf8)
        let response = try await controller.deviceState.request(method: "POST", path: "/json/state", body: payload,
                                                               contentType: "application/json; charset=utf-8")
        XCTAssertEqual(clients.count, 1)
        XCTAssertEqual(clients[0].route, .ble)
        XCTAssertEqual(clients[0].requests.first?.2, payload)
        XCTAssertEqual(clients[0].contentTypes.first, "application/json; charset=utf-8")
        XCTAssertEqual(response.status, 403)
        XCTAssertEqual(response.contentType, "application/json")
        XCTAssertEqual(response.body, Data("{\"error\":\"locked\"}".utf8))
    }

    func testRawResponseFromRetiredRouteCannotReachScreenOrReplay() async throws {
        let (persistence, device, defaults) = fixture(mode: .automatic)
        defer { _ = persistence }
        var clients: [WorkflowClient] = []
        let controller = DeviceConnectionController(device: device, defaults: defaults) { device, route in
            let client = WorkflowClient(device: device, route: route); clients.append(client); return client
        }
        defer { controller.destroy() }
        controller.connectByUser()
        clients[0].ready()
        try await settle { controller.deviceState.isOnline }
        clients[0].holdsRequests = true
        let originalEpoch = controller.deviceState.connectionEpoch
        let request = Task { try await controller.deviceState.request(method: "POST", path: "/json/cfg", body: Data("{}".utf8)) }
        try await settle { clients[0].reply != nil }
        clients[0].fail()
        try await settle { clients.count == 2 }
        clients[1].ready()
        try await settle { controller.deviceState.activeTransport == .ble }
        XCTAssertNotEqual(controller.deviceState.connectionEpoch, originalEpoch)
        let replacementEpoch = controller.deviceState.connectionEpoch
        clients[0].reply?.resume(returning: .init(status: 200, contentType: "application/json", body: Data("{}".utf8)))
        clients[0].reply = nil
        do { _ = try await request.value; XCTFail("Retired response reached the caller") }
        catch DeviceAPIError.connectionChanged {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(clients[1].requests.isEmpty)
        controller.disconnectByUser()
        XCTAssertNotEqual(controller.deviceState.connectionEpoch, replacementEpoch)
        do { _ = try await controller.deviceState.request(path: "/json"); XCTFail("Disconnected request sent") }
        catch DeviceAPIError.disconnected {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertTrue(clients[1].requests.isEmpty)
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Connection state did not settle")
        throw NSError(domain: "test-timeout", code: 1)
    }
}

@MainActor
private final class WorkflowClient: DeviceConnectionClient {
    let deviceState: DeviceWithState
    let route: DeviceConnectionType
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    var sent: [WledState] = []
    var destroyed = false
    var requests: [(String, String, Data)] = []
    var contentTypes: [String?] = []
    var holdsRequests = false
    var reply: CheckedContinuation<DeviceAPIResponse, Error>?
    init(device: Device, route: DeviceConnectionType) { deviceState = DeviceWithState(initialDevice: device); self.route = route }
    func connect() { deviceState.websocketStatus = .connecting }
    func ready() { deviceState.websocketStatus = .connected }
    func fail(requiresAction: Bool = false) {
        deviceState.requiresUserAction = requiresAction
        deviceState.connectionError = "Test route failure"
        deviceState.websocketStatus = .disconnected
    }
    func disconnect() { deviceState.websocketStatus = .disconnected }
    func destroy() { destroyed = true; disconnect() }
    func sendState(_ state: WledState) { sent.append(state); deviceState.isSending = true }
    func request(method: String, path: String, body: Data) async throws -> DeviceAPIResponse {
        requests.append((method, path, body))
        if holdsRequests { return try await withCheckedThrowingContinuation { reply = $0 } }
        return DeviceAPIResponse(status: 403, contentType: "application/json", body: Data("{\"error\":\"locked\"}".utf8))
    }
    func request(method: String, path: String, body: Data, contentType: String?) async throws -> DeviceAPIResponse {
        contentTypes.append(contentType)
        return try await request(method: method, path: path, body: body)
    }
}
