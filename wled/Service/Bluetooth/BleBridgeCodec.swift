import Foundation

/// The bridge has no request IDs: a framing failure requires a fresh connection.
enum BleBridgeCodec {
    static let maximumPayloadLength = Int(UInt16.max)

    static func chunks(_ payload: Data, maximumWriteLength: Int) throws -> [Data] {
        guard !payload.isEmpty, payload.count <= maximumPayloadLength, maximumWriteLength >= 3 else {
            throw BleBridgeSession.SessionError.invalidResponse
        }
        // Include the length prefix in the first ATT write's budget.
        var framed = Data([UInt8(payload.count & 0xff), UInt8(payload.count >> 8)])
        framed.append(payload)
        return stride(from: 0, to: framed.count, by: maximumWriteLength).map {
            framed.subdata(in: $0..<min($0 + maximumWriteLength, framed.count))
        }
    }

    static func parseResponse(_ data: Data) throws -> BleBridgeResponse {
        guard let separator = data.range(of: Data("\n\n".utf8)),
              let header = String(data: data[..<separator.lowerBound], encoding: .utf8) else {
            throw BleBridgeSession.SessionError.invalidResponse
        }
        let fields = header.split(separator: " ", maxSplits: 1)
        guard fields.count == 2, let status = Int(fields[0]), (100...599).contains(status) else {
            throw BleBridgeSession.SessionError.invalidResponse
        }
        return BleBridgeResponse(status: status, contentType: String(fields[1]), body: Data(data[separator.upperBound...]))
    }
}

struct BleFrameAssembler {
    private var expected: Int?
    private var buffer = Data()

    var progressDescription: String { "\(buffer.count)/\(expected.map(String.init) ?? "none")" }

    mutating func reset() {
        expected = nil
        buffer.removeAll(keepingCapacity: true)
    }

    mutating func append(_ chunk: Data) throws -> Data? {
        guard !chunk.isEmpty else { throw BleBridgeSession.SessionError.invalidResponse }
        if expected == nil {
            guard chunk.count >= 2 else { throw BleBridgeSession.SessionError.invalidResponse }
            let bytes = [UInt8](chunk.prefix(2))
            expected = Int(bytes[0]) | (Int(bytes[1]) << 8)
            buffer.append(chunk.dropFirst(2))
        } else {
            buffer.append(chunk)
        }
        guard let expected, expected > 0, buffer.count <= expected else {
            reset()
            throw BleBridgeSession.SessionError.invalidResponse
        }
        guard buffer.count == expected else { return nil }
        let payload = buffer
        reset()
        return payload
    }
}
