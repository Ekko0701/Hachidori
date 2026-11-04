import XCTest
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
}
