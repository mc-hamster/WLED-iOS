import Foundation
import CryptoKit

/// Transfers larger than a BLE command are staged and verified before commit.
/// No operation changes transports or retries a mutation after an ambiguous reply.
@MainActor
extension DeviceWithState {
    func workspaceRequest(method: String = "GET", path: String, body: Data = Data()) async throws -> DeviceAPIResponse {
        guard activeTransport == .ble else { return try await request(method: method, path: path, body: body) }
        let url = URLComponents(string: "wled-local://device" + path)
        let route = url?.path ?? path
        let query = Dictionary((url?.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, new in new })
        if method == "GET", route == "/edit", query["func"] != nil || query["list"] != nil {
            switch query["func"] ?? "list" {
            case "list":
                let epoch = connectionEpoch
                var all: [[String: Any]] = []
                var cursor = 0
                repeat {
                    guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
                    let reply = try await workspaceJSON("/ble/fs", ["op": "list", "cursor": cursor, "limit": 16])
                    guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
                    guard let files = reply["files"] as? [[String: Any]] else { throw WorkspaceError.invalidReply }
                    all.append(contentsOf: try files.map {
                        var file = $0
                        guard let name = file["name"] as? String else { throw WorkspaceError.invalidReply }
                        file["name"] = String(name.drop(while: { $0 == "/" }))
                        file["type"] = "file"
                        return file
                    })
                    let next = reply["next"] as? Int ?? 0
                    guard next == 0 || next > cursor, all.count <= 8192 else { throw WorkspaceError.invalidReply }
                    cursor = next
                } while cursor != 0
                return try .json(all)
            case "delete": return try .json(await workspaceJSON("/ble/fs", ["op": "delete", "path": "/" + String((query["path"] ?? "").drop(while: { $0 == "/" }))]))
            case "edit", "download": return try await workspaceFileResponse("/" + String((query["path"] ?? "").drop(while: { $0 == "/" })))
            default: throw WorkspaceError.unsupported
            }
        }
        if method == "GET", !route.hasPrefix("/json"), !route.hasPrefix("/ble/"),
           !route.hasPrefix("/settings/"), !URL(fileURLWithPath: route).pathExtension.isEmpty {
            return try await workspaceFileResponse(route)
        }
        let maximum = Int(stateInfo?.info.ble?.maxRequest ?? 4096)
        if method == "POST", body.count + method.utf8.count + path.utf8.count + 3 > maximum {
            if path == "/ble/ddp" { return try await workspaceDDP(body, maximum: maximum) }
            return try await workspaceOperation { try await workspaceTransfer(endpoint: "/ble/request", metadata: ["method": method, "path": path,
                "contentType": path.hasPrefix("/settings") ? "application/x-www-form-urlencoded" : "application/json"], data: body) }
        }
        return try await request(method: method, path: path, body: body)
    }

    private func workspaceDDP(_ body: Data, maximum: Int) async throws -> DeviceAPIResponse {
        guard let value = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let encoded = value["data"] as? String, let data = Data(base64Encoded: encoded),
              data.count >= 11, data.count <= 1428, data[0] == 2, data[3] == 0x0b,
              Int(data[9]) * 256 + Int(data[10]) == data.count - 11 else { throw WorkspaceError.invalidReply }
        let epoch = connectionEpoch
        let originalOffset = data[5...8].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let bytesPerChunk = (((maximum - 30) / 4 * 3 - 11) / 3) * 3
        guard bytesPerChunk >= 3 else { throw WorkspaceError.tooLarge }
        var offset = 11
        var response = try DeviceAPIResponse.json(["success": true])
        while offset < data.count {
            try Task.checkCancellation()
            guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
            let end = min(offset + bytesPerChunk, data.count)
            let (pixelOffset, overflow) = originalOffset.addingReportingOverflow(UInt32(offset - 11))
            guard !overflow else { throw WorkspaceError.invalidReply }
            var packet = Data(data.prefix(11))
            if end < data.count { packet[1] &= 0xfe }
            for i in 0..<4 { packet[5+i] = UInt8((pixelOffset >> ((3-i) * 8)) & 255) }
            packet[9] = UInt8((end - offset) >> 8); packet[10] = UInt8((end - offset) & 255)
            packet.append(data.subdata(in: offset..<end))
            response = try await request(method: "POST", path: "/ble/ddp",
                body: JSONSerialization.data(withJSONObject: ["data": packet.base64EncodedString()], options: [.withoutEscapingSlashes]))
            try response.requireSuccess()
            offset = end
        }
        return response
    }

    func workspaceUpload(path: String, data: Data) async throws -> DeviceAPIResponse {
        if activeTransport == .ble {
            return try await workspaceOperation { try await workspaceTransfer(endpoint: "/ble/fs", metadata: ["path": path], data: data) }
        }
        let boundary = "WLED-" + UUID().uuidString
        guard !path.contains("\r"), !path.contains("\n"), !path.contains("\"") else { throw WorkspaceError.invalidPath }
        var multipart = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"data\"; filename=\"\(path)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8)
        multipart.append(data)
        multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return try await request(method: "POST", path: "/upload", body: multipart,
                                 contentType: "multipart/form-data; boundary=\(boundary)")
    }

    private func workspaceOperation(_ operation: () async throws -> DeviceAPIResponse) async throws -> DeviceAPIResponse {
        let epoch = connectionEpoch
        return try await workspaceOperations.perform {
            guard self.activeTransport == .ble, self.connectionEpoch == epoch, self.isOnline else { throw WorkspaceError.connectionChanged }
            return try await operation()
        }
    }

    func workspaceJSON(_ path: String, _ object: [String: Any]) async throws -> [String: Any] {
        guard activeTransport == .ble else { throw WorkspaceError.connectionChanged }
        let result = try await request(method: "POST", path: path, body: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
        try result.requireSuccess()
        guard let json = try JSONSerialization.jsonObject(with: result.body) as? [String: Any] else { throw WorkspaceError.invalidReply }
        return json
    }

    private func workspaceFileResponse(_ path: String) async throws -> DeviceAPIResponse {
        do {
            return try await workspaceOperation {
                do { return try await workspaceReadFile(path) }
                catch WorkspaceError.rejected(404, _) where !path.hasSuffix(".gz") {
                    let compressed = try await workspaceReadFile(path + ".gz")
                    return DeviceAPIResponse(status: 200, contentType: Self.workspaceMIME(path), body: try WorkspaceGzip.decode(compressed.body))
                }
            }
        }
        catch WorkspaceError.rejected(let code, let message) {
            return DeviceAPIResponse(status: code, contentType: "text/plain", body: Data(message.utf8))
        }
    }

    private func workspaceReadFile(_ path: String) async throws -> DeviceAPIResponse {
        guard path.hasPrefix("/"), !path.contains("..") else { throw WorkspaceError.invalidPath }
        let epoch = connectionEpoch
        let chunkSize = min(1024, max(1, ((stateInfo?.info.ble?.maxRequest ?? 4096) - 112) / 4 * 3))
        var output = Data()
        var expectedSize: Int?
        var revision: String?
        repeat {
            try Task.checkCancellation()
            guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
            var payload: [String: Any] = ["op": "read", "path": path, "offset": output.count, "length": chunkSize]
            if let revision { payload["revision"] = revision }
            let reply = try await workspaceJSON("/ble/fs", payload)
            guard let size = reply["size"] as? Int, size >= 0, size <= 16 * 1024 * 1024,
                  expectedSize == nil || expectedSize == size,
                  let offset = reply["offset"] as? Int, offset == output.count,
                  let encoded = reply["data"] as? String, let bytes = Data(base64Encoded: encoded),
                  let next = reply["next"] as? Int, next == output.count + bytes.count,
                  next <= size, reply["eof"] as? Bool == (next == size),
                  !bytes.isEmpty || next == size else { throw WorkspaceError.invalidReply }
            guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
            guard let receivedRevision = reply["revision"] as? String, receivedRevision.count == 64 else { throw WorkspaceError.invalidReply }
            if let revision, receivedRevision != revision { throw WorkspaceError.fileChanged }
            revision = receivedRevision
            expectedSize = size
            output.append(bytes)
        } while output.count < (expectedSize ?? 0)
        if let revision {
            let actual = SHA256.hash(data: output).map { String(format: "%02x", $0) }.joined()
            guard actual == revision else { throw WorkspaceError.fileChanged }
        } else { throw WorkspaceError.invalidReply }
        return DeviceAPIResponse(status: 200, contentType: Self.workspaceMIME(path), body: output)
    }

    private func workspaceTransfer(endpoint: String, metadata: [String: Any], data: Data) async throws -> DeviceAPIResponse {
        guard data.count <= 16 * 1024 * 1024 else { throw WorkspaceError.tooLarge }
        let epoch = connectionEpoch
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var start = metadata
        start["op"] = "begin"; start["size"] = data.count; start["sha256"] = digest
        let reply = try await workspaceJSON(endpoint, start)
        guard let id = reply["id"] as? String, let maximum = reply["maxChunk"] as? Int,
              maximum > 0, maximum <= 1024 else { throw WorkspaceError.invalidReply }
        do {
            var offset = 0
            while offset < data.count {
                try Task.checkCancellation()
                guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
                let end = min(offset + maximum, data.count)
                let acknowledged = try await workspaceJSON(endpoint, ["op": "write", "id": id, "offset": offset,
                    "data": data.subdata(in: offset..<end).base64EncodedString()])
                guard acknowledged["id"] as? String == id, acknowledged["next"] as? Int == end else { throw WorkspaceError.invalidReply }
                offset = end
            }
            try Task.checkCancellation()
            guard activeTransport == .ble, connectionEpoch == epoch else { throw WorkspaceError.connectionChanged }
            let committed = try await request(method: "POST", path: endpoint,
                body: JSONSerialization.data(withJSONObject: ["op": "commit", "id": id]))
            try committed.requireSuccess()
            if endpoint == "/ble/fs" {
                guard let receipt = try JSONSerialization.jsonObject(with: committed.body) as? [String: Any],
                      receipt["size"] as? Int == data.count, receipt["sha256"] as? String == digest,
                      receipt["success"] as? Bool == true else { throw WorkspaceError.invalidReply }
            }
            return committed
        } catch {
            // The firmware also discards staged data on disconnect. Never retry commit.
            if activeTransport == .ble, connectionEpoch == epoch {
                // An uncancelled cleanup task releases the device's staging slot
                // before another queued operation begins. It still pins this session.
                let cleanup = Task { @MainActor in
                    guard self.activeTransport == .ble, self.connectionEpoch == epoch else { return }
                    _ = try? await self.workspaceJSON(endpoint, ["op": "abort", "id": id])
                }
                await cleanup.value
            }
            throw error
        }
    }

    static func workspaceMIME(_ path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "json": return "application/json"
        case "css": return "text/css"
        case "js": return "application/javascript"
        case "htm", "html": return "text/html"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ico": return "image/x-icon"
        default: return "application/octet-stream"
        }
    }
}

extension DeviceAPIResponse {
    static func json(_ value: Any) throws -> DeviceAPIResponse {
        DeviceAPIResponse(status: 200, contentType: "application/json", body: try JSONSerialization.data(withJSONObject: value))
    }

    func requireSuccess() throws {
        guard (200..<300).contains(status) else {
            let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            throw WorkspaceError.rejected(status, object?["message"] as? String ?? object?["error"] as? String ?? "WLED could not complete this request.")
        }
    }
}

enum WorkspaceError: LocalizedError {
    case invalidReply, invalidPath, connectionChanged, fileChanged, tooLarge, unsupported, useDeviceUpload
    case rejected(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidReply: return "WLED returned an incomplete transfer response. Reconnect and try again."
        case .invalidPath: return "This file path is not supported."
        case .connectionChanged: return "The connection changed during the operation. Reconnect before trying again."
        case .fileChanged: return "The file changed while it was being read. Refresh and try again."
        case .tooLarge: return "This file exceeds the device transfer limit."
        case .unsupported: return "This operation is not supported by this firmware."
        case .useDeviceUpload: return "Use the device’s file upload form for this Wi-Fi connection."
        case .rejected(let status, let message): return status == 401 ? "Unlock the device settings to continue." : message
        }
    }
}
