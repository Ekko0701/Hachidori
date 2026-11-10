import Foundation

/// A strict JSON reader that keeps object keys in the order they were written.
/// Foundation's reader returns dictionaries, which lose that order.
struct JSONReader {
    struct Failure: Error {
        let message: String
        let offset: Int
    }

    private let bytes: [UInt8]
    private var position = 0
    private static let maxDepth = 512

    init(_ text: String) {
        bytes = Array(text.utf8)
    }

    /// Reads the whole text as one JSON value.
    mutating func document() throws -> DocValue {
        skipWhitespace()
        let value = try self.value(depth: 0)
        skipWhitespace()
        guard position == bytes.count else { throw failure("Unexpected text after the value") }
        return value
    }

    private func failure(_ message: String) -> Failure {
        Failure(message: message, offset: position)
    }

    private var current: UInt8? { position < bytes.count ? bytes[position] : nil }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x0A || byte == 0x0D || byte == 0x09 {
            position += 1
        }
    }

    private mutating func value(depth: Int) throws -> DocValue {
        guard depth < Self.maxDepth else { throw failure("Nested too deeply") }
        switch current {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case .some(let byte) where byte == UInt8(ascii: "-") || (0x30...0x39).contains(byte):
            return try number()
        default:
            throw failure("Expected a value")
        }
    }

    private mutating func expect(_ word: String) throws {
        let expected = Array(word.utf8)
        guard position + expected.count <= bytes.count,
              Array(bytes[position..<position + expected.count]) == expected else {
            throw failure("Expected \(word)")
        }
        position += expected.count
    }

    private mutating func object(depth: Int) throws -> DocValue {
        position += 1
        var entries: [DocObject.Entry] = []
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            position += 1
            return .object(DocObject(entries))
        }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw failure("Expected a key") }
            let key = try string()
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw failure("Expected ':'") }
            position += 1
            skipWhitespace()
            entries.append(.init(key: key, value: try value(depth: depth + 1)))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "}"):
                position += 1
                return .object(DocObject(entries))
            default: throw failure("Expected ',' or '}'")
            }
        }
    }

    private mutating func array(depth: Int) throws -> DocValue {
        position += 1
        var items: [DocValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            position += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try value(depth: depth + 1))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): position += 1
            case UInt8(ascii: "]"):
                position += 1
                return .array(items)
            default: throw failure("Expected ',' or ']'")
            }
        }
    }

    private mutating func string() throws -> String {
        position += 1
        var out: [UInt8] = []
        while let byte = current {
            position += 1
            switch byte {
            case UInt8(ascii: "\""):
                guard let text = String(bytes: out, encoding: .utf8) else {
                    throw failure("Invalid text in a string")
                }
                return text
            case UInt8(ascii: "\\"):
                guard let escape = current else { throw failure("Unfinished escape") }
                position += 1
                switch escape {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"): out.append(escape)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"): out.append(contentsOf: try escapedScalar().utf8)
                default: throw failure("Unknown escape")
                }
            case 0..<0x20:
                throw failure("Control character in a string")
            default:
                out.append(byte)
            }
        }
        throw failure("Unfinished string")
    }

    /// The character after `\u`, joining a surrogate pair (`🐶`) into one.
    private mutating func escapedScalar() throws -> String {
        let first = try hexQuad()
        var code = first
        if (0xD800...0xDBFF).contains(first) {
            guard current == UInt8(ascii: "\\"), position + 1 < bytes.count, bytes[position + 1] == UInt8(ascii: "u") else {
                throw failure("Half of a surrogate pair")
            }
            position += 2
            let second = try hexQuad()
            guard (0xDC00...0xDFFF).contains(second) else { throw failure("Half of a surrogate pair") }
            code = 0x10000 + ((first - 0xD800) << 10) + (second - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(code) else { throw failure("Invalid \\u escape") }
        return String(scalar)
    }

    private mutating func hexQuad() throws -> UInt32 {
        guard position + 4 <= bytes.count,
              let text = String(bytes: bytes[position..<position + 4], encoding: .ascii),
              text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else {
            throw failure("Invalid \\u escape")
        }
        position += 4
        return value
    }

    private mutating func number() throws -> DocValue {
        let start = position
        var isInteger = true
        if current == UInt8(ascii: "-") { position += 1 }
        let digitsStart = position
        while let byte = current, (0x30...0x39).contains(byte) { position += 1 }
        guard position > digitsStart else { throw failure("Expected digits") }
        // JSON has no leading zeros: 01 is not a number.
        if position - digitsStart > 1, bytes[digitsStart] == 0x30 { throw failure("Leading zero") }
        if current == UInt8(ascii: ".") {
            isInteger = false
            position += 1
            let fraction = position
            while let byte = current, (0x30...0x39).contains(byte) { position += 1 }
            guard position > fraction else { throw failure("Expected digits after '.'") }
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            isInteger = false
            position += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { position += 1 }
            let exponent = position
            while let byte = current, (0x30...0x39).contains(byte) { position += 1 }
            guard position > exponent else { throw failure("Expected an exponent") }
        }
        let text = String(decoding: bytes[start..<position], as: UTF8.self)
        if isInteger, let value = Int(text) { return .int(value) }
        guard let value = Double(text) else { throw failure("Invalid number") }
        return .double(value)
    }
}
