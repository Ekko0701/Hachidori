import Foundation
import Compression

/// Minimal gzip encoder for tests (raw DEFLATE via Compression + gzip framing).
enum TestCompression {
    static func gzip(_ data: Data) -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(rawDeflate(data))
        out.append(contentsOf: withUnsafeBytes(of: crc32(data).littleEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(truncatingIfNeeded: data.count).littleEndian, Array.init))
        return out
    }

    static func rawDeflate(_ data: Data) -> Data {
        let capacity = data.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src -> Int in
            compression_encode_buffer(dst, capacity,
                                      src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        return Data(bytes: dst, count: n)
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
            table[i] = c
        }
        var crc: UInt32 = 0xFFFFFFFF
        for b in data { crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFFFFFF
    }
}
