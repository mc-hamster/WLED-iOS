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
}
