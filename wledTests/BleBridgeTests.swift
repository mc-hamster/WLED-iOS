import Testing
import Foundation
import CoreData
@testable import WLED

@MainActor
private final class TestBleTransport: BleTransport {
    var onEvent: ((BleTransportEvent) -> Void)?
    var startCount = 0
    var stopCount = 0
    var writes: [Data] = []
    var autoReady = true
    var acknowledgeWrites = true
    var responseBeforeWriteAck = false
    var respond = true
    var writeLength = 20
    private var assembler = BleFrameAssembler()

    func start() {
        startCount += 1
        if autoReady { onEvent?(.ready(maximumWriteLength: writeLength)) }
    }
    func stop() { stopCount += 1; assembler.reset() }
    func write(_ data: Data) {
        writes.append(data)
        let complete = (try? assembler.append(data)) != nil
        if complete && respond && responseBeforeWriteAck { sendResponse() }
        if acknowledgeWrites { onEvent?(.writeCompleted(nil)) }
        if complete && respond && !responseBeforeWriteAck { sendResponse() }
    }
    func sendResponse() {
        let payload = Data("200 application/json\n\n{\"success\":true}".utf8)
        for chunk in try! BleBridgeCodec.chunks(payload, maximumWriteLength: writeLength) {
            onEvent?(.response(chunk))
        }
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BleBridgeTests {
    @Test func oversizedRequestsNeverStartPairing() async {
        let transport = TestBleTransport()
        let session = BleBridgeSession(transport: transport)
        do {
            _ = try await session.request(method: "POST", path: "/json/state", body: String(repeating: "x", count: 4096))
            Issue.record("Oversized request succeeded")
        } catch { #expect(error as? BleBridgeSession.SessionError != nil) }
        #expect(transport.startCount == 0)
        #expect(transport.writes.isEmpty)
    }

    @Test func invalidATTBudgetFailsConnection() async {
        let transport = TestBleTransport()
        transport.writeLength = 2
        let session = BleBridgeSession(transport: transport)
        do { try await session.connect(); Issue.record("Invalid ATT budget succeeded") } catch { }
        #expect(transport.stopCount == 1)
    }

    @Test(arguments: [3, 20, 65, 180, 182, 244])
    func framingRoundTripAcrossATTBudgets(_ budget: Int) throws {
        for length in [1, 2, 18, 19, 20, 179, 180, 181, 244, 512, 2048, 4096, 65535] {
            let original = Data((0..<length).map { UInt8($0 % 251) })
            let chunks = try BleBridgeCodec.chunks(original, maximumWriteLength: budget)
            #expect(chunks.allSatisfy { $0.count <= budget })
            #expect(chunks[0].first == UInt8(length & 255))
            var assembler = BleFrameAssembler()
            var result: Data?
            for chunk in chunks { result = try assembler.append(chunk) }
            #expect(result == original)
        }
    }

    @Test func rejectsMalformedFramesAndRecoversAfterReset() throws {
        for data in [Data(), Data([1]), Data([0, 0]), Data([1, 0, 1, 2])] {
            var assembler = BleFrameAssembler()
            #expect(throws: (any Error).self) { try assembler.append(data) }
            assembler.reset()
            #expect(try assembler.append(Data([1, 0, 42])) == Data([42]))
        }
        #expect(throws: (any Error).self) { try BleBridgeCodec.chunks(Data(repeating: 1, count: 65536), maximumWriteLength: 20) }
        #expect(throws: (any Error).self) { try BleBridgeCodec.chunks(Data([1]), maximumWriteLength: 2) }
    }

    @Test func parsesUTF8AndBlankLinesWithoutChangingBody() throws {
        let body = Data("{\"name\":\"Lumière 🌈\"}\n\n".utf8)
        var bytes = Data("200 application/json\n\n".utf8)
        bytes.append(body)
        let response = try BleBridgeCodec.parseResponse(bytes)
        #expect(response.status == 200)
        #expect(response.body == body)
        for invalid in ["200", "abc application/json\n\n{}", "999 application/json\n\n{}", "200\n\n{}"] {
            #expect(throws: (any Error).self) { try BleBridgeCodec.parseResponse(Data(invalid.utf8)) }
        }
    }

    @Test func serialRequestsDoNotTripCancelledTimeouts() async throws {
        let transport = TestBleTransport()
        let session = BleBridgeSession(transport: transport, requestTimeout: .milliseconds(50))
        for _ in 0..<3 {
            #expect(try await session.request(method: "POST", path: "/json/state", body: String(repeating: "x", count: 130)).status == 200)
        }
        try await Task.sleep(for: .milliseconds(90))
        #expect(transport.stopCount == 0)
        #expect(transport.startCount == 1)
        #expect(transport.writes.allSatisfy { $0.count <= 20 })
        session.disconnect()
    }

    @Test func responseWaitsForLastWriteAcknowledgement() async throws {
        let transport = TestBleTransport()
        transport.responseBeforeWriteAck = true
        let session = BleBridgeSession(transport: transport)
        for _ in 0..<4 { #expect(try await session.request(method: "GET", path: "/json").status == 200) }
        session.disconnect()
    }

    @Test func concurrentConnectsShareOneTransport() async throws {
        let transport = TestBleTransport()
        transport.autoReady = false
        let session = BleBridgeSession(transport: transport)
        let first = Task { try await session.connect() }
        let second = Task { try await session.connect() }
        while transport.startCount == 0 { await Task.yield() }
        await Task.yield()
        transport.onEvent?(.ready(maximumWriteLength: 20))
        try await first.value
        try await second.value
        #expect(transport.startCount == 1)
        session.disconnect()
    }

    @Test func cancellationResumesConnectWaiter() async {
        let transport = TestBleTransport()
        transport.autoReady = false
        let session = BleBridgeSession(transport: transport)
        let task = Task { try await session.connect() }
        while transport.startCount == 0 { await Task.yield() }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled connection succeeded") } catch { #expect(error is CancellationError) }
        #expect(transport.stopCount == 1)
    }

    @Test func disconnectResumesPendingWriteAndRequest() async {
        let transport = TestBleTransport()
        transport.acknowledgeWrites = false
        transport.respond = false
        let session = BleBridgeSession(transport: transport)
        let task = Task { try await session.request(method: "GET", path: "/json") }
        while transport.writes.isEmpty { await Task.yield() }
        session.disconnect()
        do { _ = try await task.value; Issue.record("Disconnected request succeeded") } catch { #expect(error is CancellationError) }
        #expect(transport.stopCount == 1)
    }

    @Test func requestTimeoutTearsDownFramingBeforeRetry() async throws {
        let transport = TestBleTransport()
        transport.respond = false
        let session = BleBridgeSession(transport: transport, requestTimeout: .milliseconds(30))
        do { _ = try await session.request(method: "GET", path: "/json"); Issue.record("Request should time out") } catch { }
        #expect(transport.stopCount == 1)
        transport.respond = true
        #expect(try await session.request(method: "GET", path: "/json").status == 200)
        #expect(transport.startCount == 2)
        session.disconnect()
    }

    @Test func unavailableDeviceHasBoundedConnectionDeadline() async {
        let transport = TestBleTransport()
        transport.autoReady = false
        let session = BleBridgeSession(transport: transport, connectionTimeout: .milliseconds(30))
        do { try await session.connect(); Issue.record("Connection should time out") } catch { }
        #expect(transport.stopCount == 1)
    }

    @Test func requestSlotIsClaimedBeforeConnectionSuspends() async {
        let transport = TestBleTransport()
        transport.autoReady = false
        let session = BleBridgeSession(transport: transport)
        let first = Task { try await session.request(method: "GET", path: "/json") }
        while transport.startCount == 0 { await Task.yield() }
        do { _ = try await session.request(method: "GET", path: "/json"); Issue.record("Overlapping request succeeded") } catch { }
        session.disconnect()
        _ = await first.result
    }

    @Test func liveAndResponseAssemblersAreIndependent() async throws {
        let transport = TestBleTransport()
        let session = BleBridgeSession(transport: transport)
        var received: Data?
        session.onLivePayload = { received = $0 }
        try await session.connect()
        let payload = Data("{\"state\":{\"on\":true}}".utf8)
        let chunks = try BleBridgeCodec.chunks(payload, maximumWriteLength: 20)
        transport.onEvent?(.live(chunks[0]))
        _ = try await session.request(method: "GET", path: "/json")
        for chunk in chunks.dropFirst() { transport.onEvent?(.live(chunk)) }
        #expect(received == payload)
        session.disconnect()
    }

    @Test func separateControlsAreCoalescedWithoutDroppingPower() {
        let state = WledState(isOn: false).merging(WledState(brightness: 77)).merging(WledState(brightness: 120))
        #expect(state.isOn == false)
        #expect(state.brightness == 120)
    }

    @Test func upstreamDatabaseMigratesToBluetoothModel() throws {
        let bundle = Bundle(for: Device.self)
        let modelDirectory = try #require(bundle.url(forResource: "wled_native_data", withExtension: "momd"))
        let old = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("v2.mom")))
        let new = try #require(NSManagedObjectModel(contentsOf: modelDirectory.appendingPathComponent("v3.mom")))
        #expect(old.entitiesByName["Device"]?.attributesByName["bleIdentifier"] == nil)
        #expect(new.entitiesByName["Device"]?.attributesByName["bleIdentifier"] != nil)
        let mapping = try NSMappingModel.inferredMappingModel(forSourceModel: old, destinationModel: new)
        #expect(!mapping.entityMappings.isEmpty)

        // Exercise an actual on-disk store migration, including preservation of existing Wi-Fi devices.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("devices.sqlite")
        let oldCoordinator = NSPersistentStoreCoordinator(managedObjectModel: old)
        let oldStore = try oldCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = oldCoordinator
        let device = NSEntityDescription.insertNewObject(forEntityName: "Device", into: oldContext)
        device.setValue("aabbccddeeff", forKey: "macAddress")
        device.setValue("wled.local", forKey: "address")
        device.setValue("Living room", forKey: "customName")
        try oldContext.save()
        try oldCoordinator.remove(oldStore)

        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: new)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url, options: [
            NSMigratePersistentStoresAutomaticallyOption: true,
            NSInferMappingModelAutomaticallyOption: true
        ])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let migrated = try #require(context.fetch(NSFetchRequest<Device>(entityName: "Device")).first)
        #expect(migrated.macAddress == "aabbccddeeff")
        #expect(migrated.wifiAddress == "wled.local")
        #expect(migrated.customName == "Living room")
        #expect(migrated.preferredConnectionType == .wifi)
        #expect(migrated.bleIdentifier == nil)
        try coordinator.remove(store)
    }

    @Test func oldBLEIdentifierIsNeverUsedAsWiFiHostname() {
        let persistence = PersistenceController(inMemory: true)
        let device = Device(context: persistence.container.viewContext)
        device.address = UUID().uuidString
        device.bleIdentifier = UUID().uuidString
        device.connectionType = "wifi"
        #expect(device.wifiAddress.isEmpty)
        #expect(device.preferredConnectionType == .ble)
    }

    @Test func obsoletePairingSecretsAreRemovedWithoutLosingDeviceIdentity() throws {
        let persistence = PersistenceController(inMemory: true)
        let context = persistence.container.viewContext
        let device = Device(context: context)
        device.macAddress = "aabbccddeeff"
        device.address = ""
        device.bleIdentifier = UUID().uuidString
        device.blePasskey = "123456"
        device.bleSecurityMode = "passkey"
        try context.save()
        try PersistenceController.clearLegacyBluetoothSecrets(in: context)
        #expect(device.blePasskey == nil)
        #expect(device.bleSecurityMode == nil)
        #expect(device.bleIdentifierUUID != nil)
        #expect(device.macAddress == "aabbccddeeff")
    }
}
