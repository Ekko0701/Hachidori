import XCTest
import Foundation
@testable import ProxyCore

final class WebSocketSnifferTests: XCTestCase {

    private final class Collector {
        var messages: [(WebSocketMessage.Kind, String)] = []
        func sink(_ kind: WebSocketMessage.Kind, _ data: Data) {
            messages.append((kind, String(data: data, encoding: .utf8) ?? ""))
        }
    }

    /// Build a WebSocket frame (payloads <= 125 bytes for the tests).
    private func frame(opcode: UInt8, _ payload: String, fin: Bool = true, mask: [UInt8]? = nil) -> [UInt8] {
        let bytes = Array(payload.utf8)
        var out: [UInt8] = [(fin ? 0x80 : 0x00) | opcode]
        var second = UInt8(bytes.count)
        if mask != nil { second |= 0x80 }
        out.append(second)
        if let mask {
            out.append(contentsOf: mask)
            out.append(contentsOf: bytes.enumerated().map { $0.element ^ mask[$0.offset % 4] })
        } else {
            out.append(contentsOf: bytes)
        }
        return out
    }

    func testMaskedClientTextFrame() {
        let collector = Collector()
        let sniffer = WebSocketFrameSniffer(skipPreamble: false, onMessage: collector.sink)
        sniffer.consume(frame(opcode: 0x1, "hello", mask: [0x01, 0x02, 0x03, 0x04]))
        XCTAssertEqual(collector.messages.count, 1)
        XCTAssertEqual(collector.messages.first?.0, .text)
        XCTAssertEqual(collector.messages.first?.1, "hello")
    }

    func testSkipsHTTPPreambleThenParsesServerFrame() {
        let collector = Collector()
        let sniffer = WebSocketFrameSniffer(skipPreamble: true, onMessage: collector.sink)
        let preamble = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n\r\n".utf8)
        sniffer.consume(preamble + frame(opcode: 0x1, "world"))
        XCTAssertEqual(collector.messages.map(\.1), ["world"])
    }

    func testReassemblesFragmentedMessage() {
        let collector = Collector()
        let sniffer = WebSocketFrameSniffer(skipPreamble: false, onMessage: collector.sink)
        let mask: [UInt8] = [9, 9, 9, 9]
        sniffer.consume(frame(opcode: 0x1, "ab", fin: false, mask: mask))
        sniffer.consume(frame(opcode: 0x0, "cd", fin: true, mask: mask))
        XCTAssertEqual(collector.messages.map(\.1), ["abcd"])
    }

    func testHandlesSplitDelivery() {
        let collector = Collector()
        let sniffer = WebSocketFrameSniffer(skipPreamble: false, onMessage: collector.sink)
        let full = frame(opcode: 0x1, "chunked", mask: [7, 7, 7, 7])
        sniffer.consume(Array(full.prefix(3)))
        XCTAssertTrue(collector.messages.isEmpty)   // incomplete frame -> nothing yet
        sniffer.consume(Array(full.dropFirst(3)))
        XCTAssertEqual(collector.messages.map(\.1), ["chunked"])
    }
}
