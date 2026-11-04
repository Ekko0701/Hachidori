import Foundation

/// Converts HTTP bodies to text using the charset the message declares,
/// so legacy encodings such as EUC-KR or Shift_JIS render correctly.
///
/// Charset resolution order: the `charset=` parameter of `Content-Type`,
/// then an HTML `<meta charset>` / `<meta http-equiv>` or XML `encoding=`
/// declaration found in the first few KiB, then UTF-8.
public enum BodyText {
    /// Bytes scanned for an in-document charset declaration.
    static let sniffLimit = 4096

    // MARK: Charset detection

    /// The declared charset name (lower-cased), or nil when nothing declares one.
    public static func declaredCharset(contentType: String?, body: Data) -> String? {
        if let fromHeader = charsetParameter(in: contentType) { return fromHeader }
        return sniffedCharset(in: body)
    }

    /// The `charset=` parameter of a `Content-Type` value, lower-cased.
    public static func charsetParameter(in contentType: String?) -> String? {
        guard let contentType else { return nil }
        for part in contentType.split(separator: ";").dropFirst() {
            let kv = part.split(separator: "=", maxSplits: 1)
            guard kv.count == 2,
                  kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" else { continue }
            return normalize(kv[1])
        }
        return nil
    }

    /// Charset from `<meta charset=…>`, `<meta http-equiv="Content-Type" content="…charset=…">`
    /// or `<?xml encoding="…"?>` within the document prefix.
    public static func sniffedCharset(in body: Data) -> String? {
        let prefix = body.prefix(sniffLimit)
        // Lower-case ASCII copy; non-ASCII bytes are irrelevant to the markers we search for.
        let lowered = prefix.map { ($0 >= 0x41 && $0 <= 0x5A) ? $0 + 0x20 : $0 }
        if let value = attributeValue(after: Array("charset=".utf8), insideTag: Array("<meta".utf8), in: lowered) {
            return value
        }
        if let value = attributeValue(after: Array("encoding=".utf8), insideTag: Array("<?xml".utf8), in: lowered) {
            return value
        }
        return nil
    }

    /// Finds `marker` inside a tag that starts with `tagStart` and returns the value that follows it.
    private static func attributeValue(after marker: [UInt8], insideTag tagStart: [UInt8], in bytes: [UInt8]) -> String? {
        var searchFrom = 0
        while let tagRange = find(tagStart, in: bytes, from: searchFrom) {
            let tagEnd = bytes[tagRange.upperBound...].firstIndex(of: UInt8(ascii: ">")) ?? bytes.count
            if let markerRange = find(marker, in: bytes, from: tagRange.upperBound), markerRange.upperBound <= tagEnd {
                var i = markerRange.upperBound
                while i < tagEnd, bytes[i] == UInt8(ascii: "\"") || bytes[i] == UInt8(ascii: "'") || bytes[i] == 0x20 { i += 1 }
                let start = i
                while i < tagEnd, isCharsetNameByte(bytes[i]) { i += 1 }
                if i > start {
                    return normalize(String(decoding: bytes[start..<i], as: UTF8.self))
                }
            }
            searchFrom = tagEnd
        }
        return nil
    }

    private static func isCharsetNameByte(_ b: UInt8) -> Bool {
        (b >= 0x30 && b <= 0x39) || (b >= 0x61 && b <= 0x7A) || b == UInt8(ascii: "-") || b == UInt8(ascii: "_") || b == UInt8(ascii: ".") || b == UInt8(ascii: ":")
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from: Int) -> Range<Int>? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        var i = max(from, 0)
        while i + needle.count <= haystack.count {
            if haystack[i] == needle[0], Array(haystack[i..<i + needle.count]) == needle {
                return i..<i + needle.count
            }
            i += 1
        }
        return nil
    }

    private static func normalize<S: StringProtocol>(_ raw: S) -> String? {
        let name = raw.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
            .lowercased()
        return name.isEmpty ? nil : name
    }

    // MARK: Charset → String.Encoding

    /// The Foundation encoding for an IANA charset name, or nil when unknown.
    public static func encoding(forCharset charset: String) -> String.Encoding? {
        let cf = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Whether a charset name means UTF-8 (so no conversion is needed).
    public static func isUTF8(_ charset: String?) -> Bool {
        guard let charset else { return true }
        return charset == "utf-8" || charset == "utf8"
    }

    // MARK: Decoding

    /// Strict decode: the declared charset first, then UTF-8. Nil when neither fits.
    public static func decode(_ data: Data, contentType: String?) -> String? {
        if data.isEmpty { return "" }
        if let charset = declaredCharset(contentType: contentType, body: data),
           !isUTF8(charset),
           let encoding = encoding(forCharset: charset),
           let text = String(data: data, encoding: encoding) {
            return text
        }
        return String(data: data, encoding: .utf8)
    }

    /// Lossy decode for display: strict decode, else UTF-8 with replacement characters.
    public static func lossyDecode(_ data: Data, contentType: String?) -> String {
        decode(data, contentType: contentType) ?? String(decoding: data, as: UTF8.self)
    }

    // MARK: Encoding

    public struct Encoded: Sendable {
        public let data: Data
        /// The charset the text was written in; nil means UTF-8.
        public let charset: String?
    }

    /// Encodes edited text back in the declared charset when every character fits, else UTF-8.
    public static func encode(_ text: String, contentType: String?, originalBody: Data = Data()) -> Encoded {
        if let charset = declaredCharset(contentType: contentType, body: originalBody),
           !isUTF8(charset),
           let encoding = encoding(forCharset: charset),
           let data = text.data(using: encoding) {
            return Encoded(data: data, charset: charset)
        }
        return Encoded(data: Data(text.utf8), charset: nil)
    }

    /// Rewrites (or adds) the `charset=` parameter of a `Content-Type` value.
    public static func replacingCharset(in contentType: String, with charset: String) -> String {
        var parts = contentType.split(separator: ";", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var replaced = false
        for i in parts.indices.dropFirst() where parts[i].lowercased().hasPrefix("charset=") {
            parts[i] = "charset=\(charset)"
            replaced = true
        }
        if !replaced { parts.append("charset=\(charset)") }
        return parts.filter { !$0.isEmpty }.joined(separator: "; ")
    }
}
