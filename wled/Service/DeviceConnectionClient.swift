import Foundation

struct DeviceAPIResponse: Sendable {
    let status: Int
    let contentType: String
    let body: Data
}

enum DeviceAPIError: LocalizedError {
    case disconnected, connectionChanged, invalidRequest, invalidResponse, invalidUTF8

    var errorDescription: String? {
        switch self {
        case .disconnected: return "Connect to WLED before opening its controls."
        case .connectionChanged: return "The connection changed. Refresh this screen before trying again."
        case .invalidRequest: return "The request must use a local WLED path and a valid method."
        case .invalidResponse: return "WLED returned an invalid response."
        case .invalidUTF8: return "Bluetooth requests must contain UTF-8 text. Use a chunked file transfer for binary data."
        }
    }
}

/// Keeps requests on the selected device: URL authorities and protocol separators
/// must never be accepted as a relative path by either transport.
func validateDeviceAPIRequest(method: String, path: String) throws {
    guard !method.isEmpty, method.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) }),
          path.hasPrefix("/"), !path.hasPrefix("//"),
          !path.contains("\\"), !path.contains("#"),
          !path.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
        throw DeviceAPIError.invalidRequest
    }
}

@MainActor
protocol DeviceConnectionClient: AnyObject {
    var deviceState: DeviceWithState { get }
    var onDeviceStateUpdated: ((DeviceStateInfo) -> Void)? { get set }

    func connect()
    func disconnect()
    func sendState(_ state: WledState)
    func request(method: String, path: String, body: Data) async throws -> DeviceAPIResponse
    func request(method: String, path: String, body: Data, contentType: String?) async throws -> DeviceAPIResponse
    func destroy()
}

extension DeviceConnectionClient {
    func request(method: String, path: String, body: Data = Data()) async throws -> DeviceAPIResponse {
        throw DeviceAPIError.disconnected
    }

    func request(method: String, path: String, body: Data, contentType: String?) async throws -> DeviceAPIResponse {
        try await request(method: method, path: path, body: body)
    }
}
