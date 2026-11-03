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
}
