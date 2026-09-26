import Foundation
import zlib

/// Controller-uploaded tools may be stored as .htm.gz to save flash space.
/// Inflate with CRC validation and a bounded output before handing content to WebKit.
enum WorkspaceGzip {
    static func decode(_ compressed: Data, maximum: Int = 16 * 1024 * 1024) throws -> Data {
        guard !compressed.isEmpty, compressed.count <= Int(UInt32.max) else { throw WorkspaceError.invalidReply }
        var stream = z_stream()
        guard inflateInit2_(&stream, MAX_WBITS + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw WorkspaceError.invalidReply
        }
        defer { inflateEnd(&stream) }
        return try compressed.withUnsafeBytes { input in
            stream.next_in = UnsafeMutablePointer(mutating: input.bindMemory(to: Bytef.self).baseAddress)
            stream.avail_in = uInt(compressed.count)
            var output = Data()
            var chunk = [UInt8](repeating: 0, count: 16384)
            while true {
                let status = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.bindMemory(to: Bytef.self).baseAddress
                    stream.avail_out = uInt(buffer.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let written = chunk.count - Int(stream.avail_out)
                guard written <= maximum - output.count else { throw WorkspaceError.tooLarge }
                output.append(contentsOf: chunk.prefix(written))
                if status == Z_STREAM_END {
                    guard stream.avail_in == 0 else { throw WorkspaceError.invalidReply }
                    return output
                }
                guard status == Z_OK, written > 0 || stream.avail_in > 0 else { throw WorkspaceError.invalidReply }
            }
        }
    }
}
