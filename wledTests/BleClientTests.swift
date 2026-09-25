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
    var reply: CheckedContinuation<BleBridgeResponse, Error>?
    let payload = Data(#"{"state":{"on":true,"bri":128},"info":{"leds":{},"wifi":{},"name":"WLED Test","mac":"aabbccddeeff","ble":{"protocol":1,"maxRequest":4096,"security":"passkey"}}}"#.utf8)
    func connect() async throws { connections += 1 }
    func disconnect() { disconnections += 1 }
    func request(method: String, path: String, body: String) async throws -> BleBridgeResponse {
        requests.append((method, path, body))
        if deferReply { return try await withCheckedThrowingContinuation { reply = $0 } }
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
}
