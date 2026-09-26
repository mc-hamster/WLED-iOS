import XCTest
import CoreData
import Combine
@testable import WLED

@MainActor
final class DeviceClientReplacementTests: XCTestCase {
    func testWiFiToBluetoothReplacementUpdatesOnlineRowsAndSelectedControls() async throws {
        try await checkReplacement(initialStatus: .connected)
    }

    func testWiFiToBluetoothReplacementUpdatesOfflineRows() async throws {
        try await checkReplacement(initialStatus: .disconnected)
    }

    private func checkReplacement(initialStatus: WebsocketStatus) async throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let entity = try XCTUnwrap(persistence.container.managedObjectModel.entitiesByName["Device"])
        let device = Device(entity: entity, insertInto: context)
        device.macAddress = "aabbccddeeff"
        device.address = "192.0.2.1"
        device.connectionType = DeviceConnectionType.wifi.rawValue
        device.originalName = "Replacement fixture"
        device.lastSeen = initialStatus == .connected ? Int64(Date().timeIntervalSince1970 * 1000) : 0
        try context.save()

        let viewModel = DeviceWebsocketListViewModel(context: context)
        var clients: [ReplacementClient] = []
        viewModel.makeClient = { device in
            let client = ReplacementClient(device: device, initialStatus: initialStatus)
            clients.append(client)
            return client
        }
        viewModel.load()
        defer { clients.forEach { $0.destroy() } }
        let originalClient = try XCTUnwrap(clients.first)
        let originalSelection = originalClient.deviceState
        XCTAssertTrue(viewModel.allDevicesWithState.first === originalSelection)

        let editor = DeviceEditViewModel(device: originalSelection, context: context)
        let editObservation = viewModel.$allDevicesWithState.sink { editor.updateCurrentDevice(from: $0) }
        defer { editObservation.cancel() }

        // Model the Add Bluetooth upsert/edit of the existing Wi-Fi record.
        device.connectionType = DeviceConnectionType.ble.rawValue
        device.bleIdentifier = UUID().uuidString
        try context.save()
        try await waitUntil { clients.count == 2 }
        let replacementClient = clients[1]
        let replacement = replacementClient.deviceState
        XCTAssertEqual(originalSelection, replacement, "Navigation identity must remain stable")
        XCTAssertFalse(originalSelection === replacement)
        XCTAssertEqual(originalClient.destroyCount, 1)
        XCTAssertEqual(replacementClient.connectCount, 1)
        XCTAssertTrue(viewModel.allDevicesWithState.first === replacement)

        let rows = initialStatus == .connected ? viewModel.onlineDevices : viewModel.offlineDevices
        XCTAssertTrue(rows.first === replacement, "Rows must observe the current client even when IDs/order match")
        let selected = DeviceListView.currentSelection(originalSelection, from: viewModel.allDevicesWithState)
        XCTAssertTrue(selected === replacement, "An already-open detail must leave the retired client")
        replacement.websocketStatus = .connected
        XCTAssertEqual(selected?.websocketStatus, .connected)
        XCTAssertTrue(editor.device === replacement, "An open editor must follow the current client")
        XCTAssertEqual(editor.device.websocketStatus, .connected)
        var editorUpdates = 0
        let editorObservation = editor.objectWillChange.sink { editorUpdates += 1 }
        defer { editorObservation.cancel() }
        replacement.websocketStatus = .disconnected
        XCTAssertGreaterThan(editorUpdates, 0, "Current connection changes must invalidate editor content")
        let updatesBeforeRetiredChange = editorUpdates
        originalSelection.websocketStatus = .connecting
        XCTAssertEqual(editorUpdates, updatesBeforeRetiredChange, "Retired clients must no longer invalidate the editor")
        originalSelection.websocketStatus = .disconnected
        XCTAssertEqual(editor.device.websocketStatus, .disconnected, "Editor must still reflect real disconnections")
        replacement.websocketStatus = .connected
        XCTAssertEqual(originalSelection.websocketStatus, .disconnected)

        viewModel.sendState(for: try XCTUnwrap(selected), state: WledState(brightness: 37))
        XCTAssertEqual(replacementClient.sentStates.last?.brightness, 37)
        XCTAssertTrue(originalClient.sentStates.isEmpty)
        viewModel.reconnect(try XCTUnwrap(selected))
        XCTAssertEqual(replacementClient.disconnectCount, 1)
        XCTAssertEqual(replacementClient.connectCount, 2)
        XCTAssertEqual(originalClient.connectCount, 1)

        // Non-connection edits must keep the existing observed wrapper/client.
        var publications = 0
        let observation = viewModel.$allDevicesWithState.dropFirst().sink { _ in publications += 1 }
        defer { observation.cancel() }
        device.originalName = "Renamed fixture"
        try context.save()
        try await waitUntil { publications > 0 }
        XCTAssertEqual(clients.count, 2)
        XCTAssertTrue(viewModel.allDevicesWithState.first === replacement)
        XCTAssertNil(DeviceListView.currentSelection(nil, from: viewModel.allDevicesWithState),
                     "An unselected narrow layout must not auto-navigate")
        XCTAssertNil(DeviceListView.currentSelection(replacement, from: []),
                     "Deleting the selected device must clear its retired wrapper")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Core Data connection change did not replace its client within two seconds")
        throw ReplacementFailure.timedOut
    }
}

private enum ReplacementFailure: Error { case timedOut }

@MainActor
private final class ReplacementClient: DeviceConnectionClient {
    let deviceState: DeviceWithState
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)?
    let initialStatus: WebsocketStatus
    var connectCount = 0
    var disconnectCount = 0
    var destroyCount = 0
    var sentStates: [WledState] = []

    init(device: Device, initialStatus: WebsocketStatus) {
        deviceState = DeviceWithState(initialDevice: device)
        self.initialStatus = initialStatus
    }

    func connect() {
        connectCount += 1
        deviceState.websocketStatus = initialStatus
    }

    func disconnect() {
        disconnectCount += 1
        deviceState.websocketStatus = .disconnected
    }

    func destroy() {
        destroyCount += 1
        deviceState.websocketStatus = .disconnected
    }

    func sendState(_ state: WledState) { sentStates.append(state) }
}
