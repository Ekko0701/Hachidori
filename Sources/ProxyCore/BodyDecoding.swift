import Foundation
import Compression

/// Decodes HTTP `Content-Encoding` payloads (gzip, deflate, br) for display.
///
/// Uses Apple's Compression framework, so no extra dependency is needed.
/// Decoding is bounded (`maxOutputBytes`) so a hostile body can't exhaust memory.
public enum BodyDecoder {
    /// Upper bound on the decoded size (64 MiB).
    public static let maxOutputBytes = 64 * 1024 * 1024

    /// Returns the decoded bytes, or nil when `contentEncoding` is absent/identity,
    /// unknown, or the payload is malformed.
    public static func decode(_ data: Data, contentEncoding: String?) -> Data? {
        guard let encoding = contentEncoding?.trimmingCharacters(in: .whitespaces), !encoding.isEmpty,
              encoding != "identity", !data.isEmpty else { return nil }
        // Multiple encodings are applied in order; undo them last-to-first.
        let layers = encoding.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.reversed()
        var current = data
        for layer in layers {
            switch layer {
            case "gzip", "x-gzip":
                guard let raw = stripGzipHeader(current),
                      let out = inflate(raw, algorithm: COMPRESSION_ZLIB) else { return nil }
                current = out
            case "deflate":
                // RFC 9110 "deflate" is zlib-wrapped, but some servers send raw deflate.
                if let out = inflate(stripZlibHeader(current), algorithm: COMPRESSION_ZLIB) {
                    current = out
                } else if let out = inflate(current, algorithm: COMPRESSION_ZLIB) {
                    current = out
                } else { return nil }
            case "br":
                guard let out = inflate(current, algorithm: COMPRESSION_BROTLI) else { return nil }
                current = out
            case "identity":
                continue
            default:
                return nil
            }
        }
        return current
    }

    /// Whether this encoding token is one `decode` can handle.
    public static func supports(_ contentEncoding: String?) -> Bool {
        guard let e = contentEncoding?.lowercased() else { return false }
        return e.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .allSatisfy { ["gzip", "x-gzip", "deflate", "br", "identity"].contains($0) }
    }

    // MARK: - internals

    /// gzip = 10-byte header (+ optional fields) + raw DEFLATE + 8-byte trailer.
    static func stripGzipHeader(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        guard bytes.count >= 18, bytes[0] == 0x1f, bytes[1] == 0x8b, bytes[2] == 8 else { return nil }
        let flags = bytes[3]
        var index = 10
        if flags & 0x04 != 0 {                       // FEXTRA
            guard bytes.count >= index + 2 else { return nil }
            let xlen = Int(bytes[index]) | (Int(bytes[index + 1]) << 8)
            index += 2 + xlen
        }
        if flags & 0x08 != 0 {                       // FNAME
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 0x10 != 0 {                       // FCOMMENT
            guard let end = bytes[index...].firstIndex(of: 0) else { return nil }
            index = end + 1
        }
        if flags & 0x02 != 0 { index += 2 }          // FHCRC
        guard index < bytes.count - 8 else { return nil }
        return Data(bytes[index..<(bytes.count - 8)])
    }

    /// zlib = 2-byte header + raw DEFLATE + 4-byte Adler-32.
    static func stripZlibHeader(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 6, bytes[0] & 0x0f == 8, (UInt16(bytes[0]) << 8 | UInt16(bytes[1])) % 31 == 0 else {
            return data
        }
        return Data(bytes[2..<(bytes.count - 4)])
    }

    static func inflate(_ data: Data, algorithm: compression_algorithm) -> Data? {
        guard !data.isEmpty else { return nil }
        var output = Data()
        let chunk = 64 * 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: chunk)
        defer { dst.deallocate() }

        let result: Data? = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let base = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return nil }
            var stream = compression_stream(dst_ptr: dst, dst_size: chunk, src_ptr: base, src_size: 0, state: nil)
            guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, algorithm) == COMPRESSION_STATUS_OK else {
                return nil
            }
            defer { compression_stream_destroy(&stream) }
            stream.src_ptr = base
            stream.src_size = data.count
            while true {
                stream.dst_ptr = dst
                stream.dst_size = chunk
                let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                let produced = chunk - stream.dst_size
                if produced > 0 { output.append(dst, count: produced) }
                if output.count > maxOutputBytes { return nil }
                switch status {
                case COMPRESSION_STATUS_OK:
                    if produced == 0 && stream.src_size == 0 { return output }   // no progress — avoid spinning
                    continue
                case COMPRESSION_STATUS_END:
                    return output
                default:
                    return nil
                }
            }
        }
        return result
    }
}
