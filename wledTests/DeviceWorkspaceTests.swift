import Testing
import Foundation
import CryptoKit
import CoreData
@testable import WLED

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct DeviceWorkspaceTests {
    private func fixture() -> (PersistenceController, DeviceWithState) {
        let persistence = PersistenceController(inMemory: true)
        let record = Device(context: persistence.container.viewContext)
        record.macAddress = "aabbccddeeff"
        let device = DeviceWithState(initialDevice: record)
        device.activeTransport = .ble
        device.websocketStatus = .connected
        return (persistence, device)
    }

    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func chunkedReadChecksRevisionAndReassemblesExactBytes() async throws {
        let (persistence, device) = fixture()
        _ = persistence
        let bytes = Data(String(repeating: "💡WLED", count: 500).utf8)
        let digest = hash(bytes)
        var offsets: [Int] = []
        device.requestAction = { method, path, data, _ in
            #expect(method == "POST" && path == "/ble/fs")
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let offset = try #require(body["offset"] as? Int)
            offsets.append(offset)
            if offset > 0 { #expect(body["revision"] as? String == digest) }
            let next = min(offset + 700, bytes.count)
            return try .json(["size": bytes.count, "offset": offset, "next": next, "eof": next == bytes.count,
                              "revision": digest, "data": bytes.subdata(in: offset..<next).base64EncodedString()])
        }
        let result = try await device.workspaceRequest(path: "/presets.json")
        #expect(result.body == bytes)
        #expect(offsets.count > 1)
    }

    @Test func sameLengthFileMutationIsRejectedByDigest() async throws {
        let (persistence, device) = fixture(); _ = persistence
        let expected = hash(Data("old".utf8))
        device.requestAction = { _, _, _, _ in
            try .json(["size": 3, "offset": 0, "next": 3, "eof": true, "revision": expected, "data": Data("new".utf8).base64EncodedString()])
        }
        await #expect(throws: WorkspaceError.self) { try await device.workspaceRequest(path: "/presets.json") }
    }

    @Test func fileReadRequiresRevisionEvenForSingleChunk() async throws {
        let (persistence, device) = fixture(); _ = persistence
        device.requestAction = { _, _, _, _ in
            try .json(["size": 0, "offset": 0, "next": 0, "eof": true, "data": ""])
        }
        await #expect(throws: WorkspaceError.self) { try await device.workspaceRequest(path: "/presets.json") }
    }

    @Test func stagedUploadUsesServerChunkLimitAndVerifiesReceipt() async throws {
        let (persistence, device) = fixture(); _ = persistence
        let bytes = Data((0..<1537).map { UInt8($0 % 256) })
        let digest = hash(bytes)
        var collected = Data()
        var committed = false
        device.requestAction = { method, path, data, _ in
            #expect(path == "/ble/fs" && method == "POST")
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            switch body["op"] as? String {
            case "begin":
                #expect(body["sha256"] as? String == digest)
                return try .json(["id": "1234abcd", "maxChunk": 96])
            case "write":
                #expect(body["offset"] as? Int == collected.count)
                let chunk = try #require(Data(base64Encoded: body["data"] as? String ?? ""))
                #expect(chunk.count <= 96)
                collected.append(chunk)
                return try .json(["id": "1234abcd", "next": collected.count])
            case "commit":
                #expect(collected == bytes)
                committed = true
                return try .json(["success": true, "size": bytes.count, "sha256": digest])
            default: throw WorkspaceError.invalidReply
            }
        }
        _ = try await device.workspaceUpload(path: "/palette0.json", data: bytes)
        #expect(committed)
    }

    @Test func routeChangeCannotCommitOrAbortOnAnotherConnection() async throws {
        let (persistence, device) = fixture(); _ = persistence
        var operations: [String] = []
        device.requestAction = { _, _, data, _ in
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let op = body["op"] as? String ?? ""
            operations.append(op)
            if op == "begin" { return try .json(["id": "1234abcd", "maxChunk": 64]) }
            device.connectionEpoch = UUID()
            device.activeTransport = .wifi
            return try .json(["id": "1234abcd", "next": 3])
        }
        await #expect(throws: WorkspaceError.self) { try await device.workspaceUpload(path: "/skin.css", data: Data("abc".utf8)) }
        #expect(operations == ["begin", "write"])
    }

    @Test func badWriteAcknowledgementAbortsWithoutCommit() async throws {
        let (persistence, device) = fixture(); _ = persistence
        var operations: [String] = []
        device.requestAction = { _, _, data, _ in
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let op = body["op"] as? String ?? ""
            operations.append(op)
            if op == "begin" { return try .json(["id": "1234abcd", "maxChunk": 64]) }
            if op == "abort" { return try .json(["success": true]) }
            return try .json(["id": "1234abcd", "next": 999])
        }
        await #expect(throws: WorkspaceError.self) { try await device.workspaceUpload(path: "/skin.css", data: Data("abc".utf8)) }
        #expect(operations == ["begin", "write", "abort"])
    }

    @Test func pixelStreamSplitsAtNegotiatedLimitWithoutLosingPushOrOffsets() async throws {
        let (persistence, device) = fixture(); _ = persistence
        device.stateInfo = try JSONDecoder().decode(DeviceStateInfo.self, from: Data(#"{"state":{"on":true,"bri":128},"info":{"leds":{},"wifi":{},"name":"WLED","mac":"aabbccddeeff","ble":{"protocol":1,"maxRequest":512,"security":"passkey"}}}"#.utf8))
        let colors = Data((0..<1200).map { UInt8($0 % 256) })
        var packet = Data([2, 0x41, 3, 0x0b, 1, 0, 0, 0, 90, 4, 176])
        packet.append(colors)
        var collected = Data()
        var packets = 0
        device.requestAction = { method, path, body, _ in
            #expect(method == "POST" && path == "/ble/ddp")
            #expect(body.count + method.utf8.count + path.utf8.count + 3 <= 512)
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let chunk = try #require(Data(base64Encoded: json["data"] as? String ?? ""))
            #expect(chunk[0] == 2 && chunk[3] == 0x0b)
            let offset = chunk[5...8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            #expect(offset == 90 + UInt32(collected.count))
            #expect(Int(chunk[9]) * 256 + Int(chunk[10]) == chunk.count - 11)
            collected.append(chunk.dropFirst(11))
            #expect(chunk[1] & 1 == (collected.count == colors.count ? 1 : 0))
            packets += 1
            return try .json(["success": true])
        }
        _ = try await device.workspaceRequest(method: "POST", path: "/ble/ddp", body: JSONSerialization.data(withJSONObject: ["data": packet.base64EncodedString()]))
        #expect(collected == colors)
        #expect(packets > 1)
    }

    @Test func queuedUploadCannotReplayAfterReconnection() async throws {
        let (persistence, device) = fixture(); _ = persistence
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { try await device.workspaceOperations.perform {
            await withCheckedContinuation { release = $0 }
            return try .json(["success": true])
        } }
        while release == nil { await Task.yield() }
        var requests = 0
        device.requestAction = { _, _, _, _ in requests += 1; return try .json(["success": true]) }
        let upload = Task { try await device.workspaceUpload(path: "/skin.css", data: Data()) }
        for _ in 0..<10 { await Task.yield() }
        device.connectionEpoch = UUID()
        release?.resume()
        _ = try await blocker.value
        do { _ = try await upload.value; Issue.record("Queued upload replayed after reconnect") }
        catch { #expect(error is WorkspaceError) }
        #expect(requests == 0)
    }

    @Test func cancellingQueuedOperationDoesNotBlockNextOperation() async throws {
        let queue = WorkspaceOperationQueue()
        var release: CheckedContinuation<Void, Never>?
        let blocker = Task { try await queue.perform {
            await withCheckedContinuation { release = $0 }
            return try .json(["success": true])
        } }
        while release == nil { await Task.yield() }
        var cancelledRan = false
        let cancelled = Task { try await queue.perform { cancelledRan = true; return try .json(["success": true]) } }
        for _ in 0..<10 { await Task.yield() }
        cancelled.cancel()
        do { _ = try await cancelled.value; Issue.record("Cancelled operation completed") }
        catch { #expect(error is CancellationError) }
        release?.resume()
        _ = try await blocker.value
        let response = try await queue.perform { try .json(["success": true]) }
        #expect(response.status == 200)
        #expect(!cancelledRan)
    }


    @Test func uploadedCompressedToolInflatesAndRejectsCorruptOrOversizedContent() throws {
        let compressed = try #require(Data(base64Encoded: "H4sIAAAAAAAC/7PJKMnNsbNJyk+ptPNPS8vJzEtVKMnPz7HRBwvZ6IPlASZA+HImAAAA"))
        #expect(try WorkspaceGzip.decode(compressed) == Data("<html><body>Offline tool</body></html>".utf8))
        #expect(throws: WorkspaceError.self) { try WorkspaceGzip.decode(compressed, maximum: 12) }
        var corrupt = compressed
        corrupt[corrupt.count - 8] ^= 1
        #expect(throws: WorkspaceError.self) { try WorkspaceGzip.decode(corrupt) }
        #expect(throws: WorkspaceError.self) { try WorkspaceGzip.decode(Data(compressed.dropLast(2))) }
    }


    @Test func fileEditorAdaptsAbsoluteFirmwareNamesAndRelativeFormPaths() async throws {
        let (persistence, device) = fixture(); _ = persistence
        let bytes = Data("body{}".utf8)
        let digest = hash(bytes)
        var operations: [String] = []
        device.requestAction = { _, path, data, _ in
            #expect(path == "/ble/fs")
            let request = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let op = request["op"] as? String ?? ""
            operations.append(op)
            if op == "list" { return try .json(["files": [["name": "/skin.css", "size": bytes.count]], "next": NSNull()]) }
            #expect(request["path"] as? String == "/skin.css")
            if op == "read" { return try .json(["size": bytes.count, "offset": 0, "next": bytes.count, "eof": true, "revision": digest, "data": bytes.base64EncodedString()]) }
            return try .json(["success": true])
        }
        let list = try await device.workspaceRequest(path: "/edit?func=list&path=/")
        let files = try #require(JSONSerialization.jsonObject(with: list.body) as? [[String: Any]])
        #expect(files.first?["name"] as? String == "skin.css")
        #expect(files.first?["type"] as? String == "file")
        let read = try await device.workspaceRequest(path: "/edit?func=edit&path=skin.css")
        #expect(read.body == bytes)
        _ = try await device.workspaceRequest(path: "/edit?func=delete&path=/skin.css")
        #expect(operations == ["list", "read", "delete"])
    }

}
