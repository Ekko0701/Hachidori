import XCTest
import NIOHTTP1
@testable import ProxyCore

final class ProxyCoreTests: XCTestCase {

    func testSplitHostPortWithExplicitPort() {
        let (host, port) = Target.splitHostPort("example.com:8443", defaultPort: 80)
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 8443)
    }

    func testSplitHostPortWithoutPort() {
        let (host, port) = Target.splitHostPort("example.com", defaultPort: 80)
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 80)
    }

    func testAbsoluteURLStringHidesDefaultPort() {
        let tx = CapturedTransaction(method: "GET", scheme: "http", host: "example.com",
                                     port: 80, path: "/index.html")
        XCTAssertEqual(tx.absoluteURLString, "http://example.com/index.html")
    }

    func testAbsoluteURLStringShowsNonDefaultPort() {
        let tx = CapturedTransaction(method: "GET", scheme: "http", host: "localhost",
                                     port: 3000, path: "/api")
        XCTAssertEqual(tx.absoluteURLString, "http://localhost:3000/api")
    }

    func testContentTypeCategoryFromResponseHeader() {
        let tx = CapturedTransaction(method: "GET", scheme: "http", host: "example.com",
                                     port: 80, path: "/",
                                     responseHeaders: [HeaderPair(name: "Content-Type",
                                                                  value: "application/json; charset=utf-8")])
        XCTAssertEqual(tx.contentTypeCategory, .json)
    }

    func testConnectErrorIsOnlyAFailedTunnel() {
        var tx = CapturedTransaction(method: "CONNECT", scheme: "https", host: "a.example", port: 443, path: "",
                                     error: "handshake failed")
        XCTAssertTrue(tx.isConnectError)
        tx.statusCode = 200; tx.error = nil
        XCTAssertFalse(tx.isConnectError, "a tunnel that answered is not an error")
        let get = CapturedTransaction(method: "GET", scheme: "https", host: "a.example", port: 443, path: "/",
                                      error: "connection reset")
        XCTAssertFalse(get.isConnectError, "ordinary failed requests stay visible")
    }

    func testBinaryContentTypesAreNotTextual() {
        XCTAssertEqual(ContentCategory(contentType: "application/pdf"), .pdf)
        XCTAssertEqual(ContentCategory(contentType: "application/octet-stream"), .binary)
        XCTAssertEqual(ContentCategory(contentType: "font/woff2"), .binary)
        XCTAssertEqual(ContentCategory(contentType: "video/mp4"), .binary)
        XCTAssertEqual(ContentCategory(contentType: "application/x-protobuf"), .binary)
        XCTAssertFalse(ContentCategory.pdf.isTextual)
        XCTAssertFalse(ContentCategory.binary.isTextual)
        XCTAssertEqual(ContentCategory(contentType: "application/vnd.apple.mpegurl"), .other, "playlists stay text-like")
        XCTAssertEqual(ContentCategory(contentType: "application/json; charset=utf-8"), .json)
    }

    func testClientDeviceNormalizesMappedIPv4AndDetectsLocal() {
        XCTAssertEqual(ClientDevice.normalize("::ffff:192.168.0.4"), "192.168.0.4")
        XCTAssertEqual(ClientDevice.normalize("192.168.0.4"), "192.168.0.4")
        XCTAssertEqual(ClientDevice.normalize("fe80::1"), "fe80::1")
        XCTAssertTrue(ClientDevice.isLocal("127.0.0.1"))
        XCTAssertTrue(ClientDevice.isLocal("::1"))
        XCTAssertTrue(ClientDevice.isLocal(nil))
        XCTAssertFalse(ClientDevice.isLocal("192.168.0.4"))
    }

    func testClientDeviceKindFromUserAgents() {
        XCTAssertEqual(ClientDevice.kind(forUserAgents: ["Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X)"]), .iphone)
        XCTAssertEqual(ClientDevice.kind(forUserAgents: ["Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)", "MyApp/1.0 CFNetwork/1490 Darwin/23.0"]), .ipad)
        XCTAssertEqual(ClientDevice.kind(forUserAgents: ["okhttp/4.12.0"]), .android)
        XCTAssertEqual(ClientDevice.kind(forUserAgents: ["Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0)"]), .mac)
        XCTAssertEqual(ClientDevice.kind(forUserAgents: ["curl/8.4.0"]), .unknown)
        XCTAssertEqual(ClientDevice.kind(forUserAgents: [String]()), .unknown)
    }

    func testEditedRequestHeadersReframeTheBody() {
        let pairs = [HeaderPair(name: "Content-Type", value: "application/pdf"),
                     HeaderPair(name: "Content-Length", value: "5"),
                     HeaderPair(name: "Transfer-Encoding", value: "chunked"),
                     HeaderPair(name: "", value: "dropped")]
        let headers = RequestForwarder.editedRequestHeaders(pairs, bodyCount: 2048, host: "example.com")
        XCTAssertEqual(headers[canonicalForm: "Content-Length"], ["2048"])
        XCTAssertTrue(headers[canonicalForm: "Transfer-Encoding"].isEmpty)
        XCTAssertEqual(headers.first(name: "Content-Type"), "application/pdf")
        XCTAssertEqual(headers.first(name: "Host"), "example.com")
        XCTAssertEqual(headers.count, 3)
    }

    func testEditedRequestHeadersLeaveABodylessGetUnframed() {
        let headers = RequestForwarder.editedRequestHeaders([HeaderPair(name: "Host", value: "a.test")],
                                                       bodyCount: 0, host: "ignored.test")
        XCTAssertNil(headers.first(name: "Content-Length"))
        XCTAssertEqual(headers.first(name: "Host"), "a.test")
    }
}
