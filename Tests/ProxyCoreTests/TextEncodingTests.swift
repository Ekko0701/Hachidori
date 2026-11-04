import XCTest
import NIOCore
import NIOHTTP1
@testable import ProxyCore

final class TextEncodingTests: XCTestCase {
    private var eucKR: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
    }

    func testCharsetParameterFromContentType() {
        XCTAssertEqual(BodyText.charsetParameter(in: "text/html; charset=EUC-KR"), "euc-kr")
        XCTAssertEqual(BodyText.charsetParameter(in: "text/html;charset=\"utf-8\""), "utf-8")
        XCTAssertNil(BodyText.charsetParameter(in: "text/html"))
        XCTAssertNil(BodyText.charsetParameter(in: nil))
    }

    func testSniffsMetaCharsetAndXMLDeclaration() {
        XCTAssertEqual(BodyText.sniffedCharset(in: Data("<!DOCTYPE html><html><head><meta charset=\"euc-kr\"></head>".utf8)), "euc-kr")
        XCTAssertEqual(BodyText.sniffedCharset(in: Data("<meta http-equiv=\"Content-Type\" content=\"text/html; charset=Shift_JIS\">".utf8)), "shift_jis")
        XCTAssertEqual(BodyText.sniffedCharset(in: Data("<?xml version=\"1.0\" encoding=\"ISO-8859-1\"?><root/>".utf8)), "iso-8859-1")
        XCTAssertNil(BodyText.sniffedCharset(in: Data("<html><body>charset=nope</body></html>".utf8)))
    }

    func testDecodesEUCKRFromHeader() throws {
        let data = try XCTUnwrap("한글 테스트".data(using: eucKR))
        XCTAssertNil(String(data: data, encoding: .utf8), "sanity: not valid UTF-8")
        XCTAssertEqual(BodyText.decode(data, contentType: "text/html; charset=euc-kr"), "한글 테스트")
    }

    func testDecodesEUCKRFromMetaTag() throws {
        let html = "<html><head><meta charset=\"euc-kr\"></head><body>한글</body></html>"
        let data = try XCTUnwrap(html.data(using: eucKR))
        XCTAssertEqual(BodyText.decode(data, contentType: "text/html"), html)
    }

    func testFallsBackToUTF8() {
        let data = Data("plain utf-8 한글".utf8)
        XCTAssertEqual(BodyText.decode(data, contentType: nil), "plain utf-8 한글")
        XCTAssertEqual(BodyText.decode(data, contentType: "text/plain; charset=bogus-charset"), "plain utf-8 한글")
        XCTAssertNil(BodyText.decode(Data([0xFF, 0xFE, 0x00, 0x01]), contentType: nil))
    }

    func testEncodeRoundTripsInDeclaredCharset() throws {
        let encoded = BodyText.encode("수정된 본문", contentType: "text/html; charset=euc-kr")
        XCTAssertEqual(encoded.charset, "euc-kr")
        XCTAssertEqual(String(data: encoded.data, encoding: eucKR), "수정된 본문")

        let emoji = BodyText.encode("😀", contentType: "text/html; charset=euc-kr")
        XCTAssertNil(emoji.charset, "unrepresentable text falls back to UTF-8")
        XCTAssertEqual(emoji.data, Data("😀".utf8))
    }

    func testReplacingCharset() {
        XCTAssertEqual(BodyText.replacingCharset(in: "text/html; charset=euc-kr", with: "utf-8"), "text/html; charset=utf-8")
        XCTAssertEqual(BodyText.replacingCharset(in: "text/html", with: "utf-8"), "text/html; charset=utf-8")
    }

    func testRewriteRuleUpgradesLegacyCharsetToUTF8() {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/html; charset=euc-kr")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        let original = CollectedResponse(head: head, body: ByteBufferAllocator().buffer(capacity: 0))
        var rule = OverrideRule(name: "r", urlContains: "x", contentType: "")
        rule.overrideBody = true
        rule.body = "<p>한글</p>"
        let rewritten = RequestForwarder.applyRule(rule, to: original, allocator: ByteBufferAllocator())
        XCTAssertEqual(rewritten.head.headers.first(name: "Content-Type"), "text/html; charset=utf-8")

        var keep = rule
        keep.contentType = "text/plain; charset=euc-kr"
        let kept = RequestForwarder.applyRule(keep, to: original, allocator: ByteBufferAllocator())
        XCTAssertEqual(kept.head.headers.first(name: "Content-Type"), "text/plain; charset=euc-kr",
                       "an explicit rule Content-Type is respected")
    }
}
