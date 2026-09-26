import Testing
import Foundation
import CoreData
@testable import WLED

@MainActor
private final class TestBleConnection: BleBridgeConnection {
    var onLivePayload: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var connections = 0
    var disconnections = 0
    var requests: [(String, String, String)] = []
    var deferReply = false
    var deferNextPost = false
    var reply: CheckedContinuation<BleBridgeResponse, Error>?
    let payload = Data(#"{"state":{"on":true,"bri":128},"info":{"leds":{},"wifi":{},"name":"WLED Test","mac":"aabbccddeeff","ble":{"protocol":1,"maxRequest":4096,"security":"passkey"}}}"#.utf8)
    func connect() async throws { connections += 1 }
    func disconnect() { disconnections += 1 }
    func request(method: String, path: String, body: String) async throws -> BleBridgeResponse {
        requests.append((method, path, body))
        if deferReply || (deferNextPost && method == "POST") {
            deferNextPost = false
            return try await withCheckedThrowingContinuation { reply = $0 }
        }
        return response()
    }
    func response() -> BleBridgeResponse { BleBridgeResponse(status: 200, contentType: "application/json", body: payload) }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BleClientTests {
    private func device(in persistence: PersistenceController) -> Device {
        let device = Device(context: persistence.container.viewContext)
        device.macAddress = "aabbccddeeff"
        device.address = ""
        device.connectionType = "ble"
        device.bleIdentifier = UUID().uuidString
        return device
    }

    @Test func updatesStateAndImmediatelyReportsRadioDisconnect() async {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        let client = BleClient(device: device(in: persistence), session: session)
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        #expect(client.deviceState.stateInfo?.state.brightness == 128)
        client.connect()
        #expect(session.connections == 1)
        session.onDisconnect?(BleBridgeSession.SessionError.disconnected)
        #expect(client.deviceState.websocketStatus == .disconnected)
        #expect(client.deviceState.connectionError != nil)
        client.destroy()
    }

    @Test func lateReplyCannotResurrectDestroyedClient() async {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        session.deferReply = true
        let client = BleClient(device: device(in: persistence), session: session)
        client.connect()
        while session.reply == nil { await Task.yield() }
        client.destroy()
        session.reply?.resume(returning: session.response())
        session.reply = nil
        await Task.yield()
        #expect(client.deviceState.websocketStatus == .disconnected)
        #expect(client.deviceState.stateInfo == nil)
    }

    @Test func nativeControlsSendJSONAndRefreshAuthoritativeState() async throws {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        let client = BleClient(device: device(in: persistence), session: session)
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        client.sendState(WledState(isOn: false))
        client.sendState(WledState(brightness: 42))
        while session.requests.count < 3 { await Task.yield() }
        let command = try #require(session.requests.first { $0.0 == "POST" })
        let state = try JSONDecoder().decode(WledState.self, from: Data(command.2.utf8))
        #expect(state.isOn == false)
        #expect(state.brightness == 42)
        #expect(session.requests.last?.1 == "/json")
        client.destroy()
    }

    @Test func pairingFailuresRequireAnExplicitRetry() async throws {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        let client = BleClient(device: device(in: persistence), session: session)
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        session.onDisconnect?(BleBridgeSession.SessionError.pairingFailed("Pair again"))
        try await Task.sleep(for: .seconds(3))
        #expect(session.connections == 1)
        #expect(client.deviceState.websocketStatus == .disconnected)
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        #expect(session.connections == 2)
        client.destroy()
    }

    @Test func heldPostPreservesPartialSameSegmentEditsAndLatestFieldValues() async throws {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        let client = BleClient(device: device(in: persistence), session: session)
        defer { client.destroy() }
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        session.deferNextPost = true
        client.sendState(WledState(isOn: true))
        while session.reply == nil { await Task.yield() }
        client.sendState(WledState(segment: [Segment(id: 4, brightness: 41,
                            colors: [[1, 2, 3, 4], [5, 6, 7, 8]], effect: 2, effectSpeed: 4)]))
        client.sendState(WledState(segment: [Segment(id: 4, colors: [[9, 10, 11]], palette: 6)]))
        client.sendState(WledState(segment: [Segment(id: 4, effectSpeed: 55)]))
        #expect(session.requests.filter { $0.0 == "POST" }.count == 1)
        let held = try #require(session.reply)
        session.reply = nil
        held.resume(returning: session.response())
        while session.requests.count < 5 { await Task.yield() }
        let commands = session.requests.filter { $0.0 == "POST" }
        #expect(commands.count == 2)
        let state = try JSONDecoder().decode(WledState.self, from: Data(commands[1].2.utf8))
        let segments = try #require(state.segment)
        #expect(segments.count == 1)
        let segment = try #require(segments.first)
        #expect(segment.id == 4)
        #expect(segment.brightness == 41)
        #expect(segment.effect == 2)
        #expect(segment.effectSpeed == 55)
        #expect(segment.palette == 6)
        #expect(segment.colors == [[9, 10, 11], [5, 6, 7, 8]])
        #expect(session.requests.last?.1 == "/json")
    }

    @Test func heldPostKeepsDifferentSegmentIDsAndExplicitFalseAndZero() async throws {
        let persistence = PersistenceController(inMemory: true)
        let session = TestBleConnection()
        let client = BleClient(device: device(in: persistence), session: session)
        defer { client.destroy() }
        client.connect()
        while client.deviceState.websocketStatus != .connected { await Task.yield() }
        session.deferNextPost = true
        client.sendState(WledState(brightness: 42))
        while session.reply == nil { await Task.yield() }
        client.sendState(WledState(segment: [Segment(id: 2, colors: [[1, 2, 3]], effectSpeed: 99,
                            isSelected: true, isReversed: true)]))
        client.sendState(WledState(segment: [Segment(id: 6, brightness: 75, effect: 3)]))
        client.sendState(WledState(segment: [Segment(id: 2, effectSpeed: 0,
                            isSelected: false, isReversed: false, isMirrored: true)]))
        let held = try #require(session.reply)
        session.reply = nil
        held.resume(returning: session.response())
        while session.requests.count < 5 { await Task.yield() }
        let commands = session.requests.filter { $0.0 == "POST" }
        #expect(commands.count == 2)
        let state = try JSONDecoder().decode(WledState.self, from: Data(commands[1].2.utf8))
        let segments = try #require(state.segment)
        #expect(segments.map(\.id) == [2, 6])
        let first = try #require(segments.first)
        #expect(first.colors == [[1, 2, 3]])
        #expect(first.effectSpeed == 0)
        #expect(first.isSelected == false)
        #expect(first.isReversed == false)
        #expect(first.isMirrored == true)
        let second = try #require(segments.last)
        #expect(second.brightness == 75)
        #expect(second.effect == 3)
    }

    @Test func positionalAndRepeatedSegmentArraysKeepTheirOriginalShape() {
        let older = WledState(segment: [Segment(id: 7, brightness: 30)])
        let positional = older.merging(WledState(segment: [Segment(effect: 2), Segment(id: 7, palette: 3)]))
        #expect(positional.segment?.count == 2)
        #expect(positional.segment?[0].id == nil)
        #expect(positional.segment?[0].effect == 2)
        #expect(positional.segment?[1].brightness == nil)
        let repeated = older.merging(WledState(segment: [Segment(id: 7, isOn: false), Segment(id: 7, isOn: true)]))
        #expect(repeated.segment?.count == 2)
        #expect(repeated.segment?[0].isOn == false)
        #expect(repeated.segment?[1].isOn == true)
    }

    @Test func emptyColorSlotsPreserveIndependentPendingColors() {
        let older = WledState(segment: [Segment(id: 1, colors: [[1, 2, 3, 4], [5, 6, 7, 8]])])
        let newer = WledState(segment: [Segment(id: 1, colors: [[], [], [9, 10, 11]])])
        #expect(older.merging(newer).segment?.first?.colors == [[1, 2, 3, 4], [5, 6, 7, 8], [9, 10, 11]])
    }

    @Test func geometryCommandsDoNotInheritFieldsThatOverrideTheirMeaning() {
        let older = WledState(segment: [Segment(id: 1, stop: 50)])
        let newer = WledState(segment: [Segment(id: 1, length: 20)])
        let merged = older.merging(newer)
        #expect(merged.segment?.first?.stop == nil)
        #expect(merged.segment?.first?.length == 20)
    }
}
