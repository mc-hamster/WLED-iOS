import Foundation
import Testing
@testable import WLED

@MainActor
private final class QueuedBleFixture: BleBridgeConnection {
    var onLivePayload: ((Data) -> Void)?
    var onDisconnect: ((Error) -> Void)?
    var paths: [String] = []
    var replies: [CheckedContinuation<BleBridgeResponse, Error>] = []
    func connect() async throws {}
    func disconnect() {}
    func request(method: String, path: String, body: String) async throws -> BleBridgeResponse {
        paths.append(path)
        return try await withCheckedThrowingContinuation { replies.append($0) }
    }
    func finish(_ body: String = "{}") {
        replies.removeFirst().resume(returning: .init(status: 200, contentType: "application/json", body: Data(body.utf8)))
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BleRequestQueueTests {
    @Test func simultaneousConsumersUseFIFO() async throws {
        let connection = QueuedBleFixture()
        let queue = BleRequestQueue(session: connection)
        let first = Task { try await queue.request(method: "GET", path: "/json/effects") }
        while connection.paths.isEmpty { await Task.yield() }
        let second = Task { try await queue.request(method: "POST", path: "/json/state", body: "{\"bri\":20}") }
        for _ in 0..<10 { await Task.yield() }
        #expect(connection.paths == ["/json/effects"])
        connection.finish("[\"Solid\"]")
        #expect(try await first.value.body == Data("[\"Solid\"]".utf8))
        while connection.paths.count < 2 { await Task.yield() }
        #expect(connection.paths == ["/json/effects", "/json/state"])
        connection.finish()
        #expect(try await second.value.status == 200)
    }

    @Test func cancelledQueuedWriteNeverReachesDevice() async throws {
        let connection = QueuedBleFixture()
        let queue = BleRequestQueue(session: connection)
        let first = Task { try await queue.request(method: "GET", path: "/json") }
        while connection.paths.isEmpty { await Task.yield() }
        let cancelled = Task { try await queue.request(method: "POST", path: "/json/state", body: "{\"on\":false}") }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled queued write succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        connection.finish()
        _ = try await first.value
        for _ in 0..<10 { await Task.yield() }
        #expect(connection.paths == ["/json"])
    }

    @Test func cancelledActiveReadDrainsBeforeFollowingRequest() async throws {
        let connection = QueuedBleFixture()
        let queue = BleRequestQueue(session: connection)
        let first = Task { try await queue.request(method: "GET", path: "/presets.json") }
        while connection.paths.isEmpty { await Task.yield() }
        first.cancel()
        do { _ = try await first.value; Issue.record("Cancelled request succeeded") }
        catch is CancellationError {} catch { Issue.record("Unexpected error: \(error)") }
        let next = Task { try await queue.request(method: "GET", path: "/json") }
        for _ in 0..<10 { await Task.yield() }
        #expect(connection.paths == ["/presets.json"])
        connection.finish("{\"late\":true}")
        while connection.paths.count < 2 { await Task.yield() }
        connection.finish("{\"current\":true}")
        #expect(try await next.value.body == Data("{\"current\":true}".utf8))
    }

    @Test func disconnectRetiresActiveAndQueuedRequestsWithoutReplay() async throws {
        let connection = QueuedBleFixture()
        let queue = BleRequestQueue(session: connection)
        let first = Task { try await queue.request(method: "GET", path: "/old") }
        while connection.paths.isEmpty { await Task.yield() }
        let pending = Task { try await queue.request(method: "POST", path: "/cancelled") }
        for _ in 0..<10 { await Task.yield() }
        queue.cancelAll(throwing: DeviceAPIError.connectionChanged)
        for task in [first, pending] {
            do { _ = try await task.value; Issue.record("Retired request succeeded") }
            catch DeviceAPIError.connectionChanged {} catch { Issue.record("Unexpected error: \(error)") }
        }
        let fresh = Task { try await queue.request(method: "GET", path: "/fresh") }
        while connection.paths.count < 2 { await Task.yield() }
        connection.finish("{\"old\":true}")
        connection.finish("{\"fresh\":true}")
        #expect(try await fresh.value.body == Data("{\"fresh\":true}".utf8))
        #expect(connection.paths == ["/old", "/fresh"])
    }

    @Test func requestValidationRejectsRemoteAuthoritiesAndWireInjection() throws {
        for path in ["https://example.com/json", "//example.com/json", "/json\n\nPOST /json/state", "/json#fragment", "/\\remote"] {
            #expect(throws: DeviceAPIError.self) { try validateDeviceAPIRequest(method: "GET", path: path) }
        }
        for method in ["", "GET /json", "GET\nPOST"] {
            #expect(throws: DeviceAPIError.self) { try validateDeviceAPIRequest(method: method, path: "/json") }
        }
        try validateDeviceAPIRequest(method: "POST", path: "/json/cfg?pin=1234")
    }
}
