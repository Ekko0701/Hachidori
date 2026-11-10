import Foundation
import Yams

/// A YAML or JSON value. Objects keep the order their keys were written in, so
/// schema properties show in the order the document's author chose.
public enum DocValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([DocValue])
    case object(DocObject)

    public var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var bool: Bool? {
        if case .bool(let value) = self { return value }
        return nil
    }

    public var int: Int? {
        if case .int(let value) = self { return value }
        return nil
    }

    public var double: Double? {
        switch self {
        case .double(let value): return value
        case .int(let value): return Double(value)
        default: return nil
        }
    }

    public var array: [DocValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var object: DocObject? {
        if case .object(let value) = self { return value }
        return nil
    }

    public subscript(key: String) -> DocValue? { object?[key] }

    /// The value as JSON text, for showing examples, defaults and enum values.
    public func jsonText(pretty: Bool = false) -> String {
        var out = ""
        writeJSON(to: &out, pretty: pretty, indent: 0)
        return out
    }

    private func writeJSON(to out: inout String, pretty: Bool, indent: Int) {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let closePad = pretty ? String(repeating: "  ", count: indent) : ""
        let newline = pretty ? "\n" : ""
        switch self {
        case .null: out += "null"
        case .bool(let value): out += value ? "true" : "false"
        case .int(let value): out += String(value)
        case .double(let value): out += value.isFinite ? String(value) : "null"
        case .string(let value): out += Self.quoted(value)
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + newline
            for (i, item) in items.enumerated() {
                out += pad
                item.writeJSON(to: &out, pretty: pretty, indent: indent + 1)
                out += (i < items.count - 1 ? "," : "") + newline
            }
            out += closePad + "]"
        case .object(let object):
            if object.entries.isEmpty { out += "{}"; return }
            out += "{" + newline
            for (i, entry) in object.entries.enumerated() {
                out += pad + Self.quoted(entry.key) + (pretty ? ": " : ":")
                entry.value.writeJSON(to: &out, pretty: pretty, indent: indent + 1)
                out += (i < object.entries.count - 1 ? "," : "") + newline
            }
            out += closePad + "}"
        }
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }
}

/// An object whose keys keep their written order.
public struct DocObject: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let key: String
        public let value: DocValue
    }

    public let entries: [Entry]
    private let index: [String: Int]

    public init(_ entries: [Entry]) {
        self.entries = entries
        var index: [String: Int] = [:]
        // A repeated key keeps its last value, as YAML and JSON readers do.
        for (i, entry) in entries.enumerated() { index[entry.key] = i }
        self.index = index
    }

    public subscript(key: String) -> DocValue? {
        index[key].map { entries[$0].value }
    }

    public static func == (lhs: DocObject, rhs: DocObject) -> Bool { lhs.entries == rhs.entries }
}

extension DocValue {
    /// Reads YAML or JSON text. Text that starts like JSON goes to the JSON reader
    /// first; if that fails it may still be YAML written in flow style.
    static func parse(text: String) throws -> DocValue {
        if let first = text.first(where: { !$0.isWhitespace }), first == "{" || first == "[" {
            var reader = JSONReader(text)
            if let value = try? reader.document() { return value }
        }
        do {
            guard let node = try Yams.compose(yaml: text) else { throw APIDocError.notOpenAPI }
            return DocValue(node: node)
        } catch let error as APIDocError {
            throw error
        } catch {
            throw APIDocError.syntax(String(describing: error))
        }
    }

    private init(node: Node) {
        if let mapping = node.mapping {
            var entries: [DocObject.Entry] = []
            entries.reserveCapacity(mapping.count)
            for (key, value) in mapping {
                entries.append(.init(key: key.scalar?.string ?? "", value: DocValue(node: value)))
            }
            self = .object(DocObject(entries))
        } else if let sequence = node.sequence {
            self = .array(sequence.map(DocValue.init(node:)))
        } else if let scalar = node.scalar {
            // Only unquoted scalars can be anything but a string.
            self = scalar.style == .plain || scalar.style == .any
                ? DocValue(plainScalar: scalar.string)
                : .string(scalar.string)
        } else {
            self = .null
        }
    }

    /// YAML 1.2 core schema. Words like `yes` and `on` stay strings, so `NO` as a
    /// country code is not read as false.
    init(plainScalar text: String) {
        switch text {
        case "", "~", "null", "Null", "NULL": self = .null
        case "true", "True", "TRUE": self = .bool(true)
        case "false", "False", "FALSE": self = .bool(false)
        case ".inf", ".Inf", ".INF", "+.inf", "+.Inf", "+.INF": self = .double(.infinity)
        case "-.inf", "-.Inf", "-.INF": self = .double(-.infinity)
        case ".nan", ".NaN", ".NAN": self = .double(.nan)
        default:
            if let value = Self.integer(text) {
                self = .int(value)
            } else if Self.looksLikeFloat(text), let value = Double(text) {
                self = .double(value)
            } else {
                self = .string(text)
            }
        }
    }

    private static func integer(_ text: String) -> Int? {
        if text.hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        if text.hasPrefix("0o") { return Int(text.dropFirst(2), radix: 8) }
        var digits = Substring(text)
        if digits.hasPrefix("-") || digits.hasPrefix("+") { digits = digits.dropFirst() }
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(text)
    }

    /// Digits with a decimal point or exponent; `Double("nan")` and the like are not YAML floats.
    private static func looksLikeFloat(_ text: String) -> Bool {
        var sawDigit = false
        var previous: Character?
        for character in text {
            switch character {
            case "0"..."9": sawDigit = true
            case "+", "-":
                if let previous, previous != "e", previous != "E" { return false }
            case ".", "e", "E": break
            default: return false
            }
            previous = character
        }
        return sawDigit
    }
}
