import XCTest
import Compression
@testable import ProxyCore

final class BodyDecoderTests: XCTestCase {

    func testGzipRoundTrip() throws {
        let original = Data(String(repeating: "{\"hello\":\"world\"}\n", count: 200).utf8)
        let gz = try gzip(original)
        XCTAssertEqual(BodyDecoder.decode(gz, contentEncoding: "gzip"), original)
        XCTAssertEqual(BodyDecoder.decode(gz, contentEncoding: "x-gzip"), original)
    }

    func testZlibDeflateRoundTrip() throws {
        let original = Data("deflate me please ".utf8) + Data(repeating: 0x41, count: 1000)
        let raw = try rawDeflate(original)
        // zlib-wrapped (RFC-correct "deflate")
        var zlib = Data([0x78, 0x9c]) + raw
        zlib.append(contentsOf: adler32(original).bigEndianBytes)
        XCTAssertEqual(BodyDecoder.decode(zlib, contentEncoding: "deflate"), original)
        // raw deflate (what some servers actually send)
        XCTAssertEqual(BodyDecoder.decode(raw, contentEncoding: "deflate"), original)
    }

    func testIdentityAndUnknownEncodingsReturnNil() {
        let data = Data("plain".utf8)
        XCTAssertNil(BodyDecoder.decode(data, contentEncoding: nil))
        XCTAssertNil(BodyDecoder.decode(data, contentEncoding: "identity"))
        XCTAssertNil(BodyDecoder.decode(data, contentEncoding: "zstd"))
        XCTAssertNil(BodyDecoder.decode(data, contentEncoding: "gzip"))   // malformed → nil, not crash
    }

    func testCapturedTransactionExposesDecodedBody() throws {
        let original = Data("<html><body>hi</body></html>".utf8)
        let tx = CapturedTransaction(method: "GET", scheme: "https", host: "example.com", port: 443, path: "/",
                                     statusCode: 200,
                                     responseHeaders: [HeaderPair(name: "Content-Type", value: "text/html"),
                                                       HeaderPair(name: "Content-Encoding", value: "gzip")],
                                     responseBody: try gzip(original))
        XCTAssertEqual(tx.decodedResponseBody, original)
        XCTAssertEqual(tx.contentTypeCategory, .html)
        XCTAssertEqual(tx.responseContentEncoding, "gzip")
    }

    // MARK: helpers

    private func rawDeflate(_ data: Data) throws -> Data {
        let capacity = data.count + 1024
        let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
        defer { dst.deallocate() }
        let n = data.withUnsafeBytes { src -> Int in
            compression_encode_buffer(dst, capacity,
                                      src.baseAddress!.assumingMemoryBound(to: UInt8.self), data.count,
                                      nil, COMPRESSION_ZLIB)
        }
        XCTAssertGreaterThan(n, 0)
        return Data(bytes: dst, count: n)
    }

    private func gzip(_ data: Data) throws -> Data {
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03])
        out.append(try rawDeflate(data))
        out.append(contentsOf: crc32(data).littleEndianBytes)
        out.append(contentsOf: UInt32(truncatingIfNeeded: data.count).littleEndianBytes)
        return out
    }

    private func crc32(_ data: Data) -> UInt32 {
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

    private func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in data {
            a = (a + UInt32(byte)) % 65521
            b = (b + a) % 65521
        }
        return (b << 16) | a
    }
}

private extension UInt32 {
    var littleEndianBytes: [UInt8] { withUnsafeBytes(of: self.littleEndian, Array.init) }
    var bigEndianBytes: [UInt8] { withUnsafeBytes(of: self.bigEndian, Array.init) }
}
