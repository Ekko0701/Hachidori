import SwiftUI
import AppKit
import WebKit
import ProxyCore

enum BodyMode: String, CaseIterable, Identifiable {
    case pretty, raw, preview, hex
    var id: String { rawValue }
    var title: String {
        switch self {
        case .pretty: return "Pretty"
        case .raw: return "Raw"
        case .preview: return "Preview"
        case .hex: return "Hex"
        }
    }
}

/// Body viewer with Pretty (highlighted) / Raw / Preview / Hex modes.
struct BodySection: View {
    @Environment(AppModel.self) private var model
    let title: String
    let raw: Data
    let decoded: Data
    let category: ContentCategory
    let encoding: String?
    let contentType: String?
    let baseURL: URL?

    @State private var mode: BodyMode = .pretty
    @State private var highlighted: AttributedString?
    @State private var highlightKey: Int = 0
    /// Pretty-printed text, computed once per body: pretty-printing a large
    /// JSON body is costly and several parts of the view need the answer.
    @State private var pretty: String?

    private var canPreview: Bool { category == .image || category == .html }
    private var canPretty: Bool { pretty != nil }
    private var availableModes: [BodyMode] {
        var modes: [BodyMode] = []
        if canPretty { modes.append(.pretty) }
        modes.append(.raw)
        if canPreview { modes.append(.preview) }
        modes.append(.hex)
        return modes
    }
    private var decodeFailed: Bool {
        encoding != nil && encoding?.lowercased() != "identity" && decoded == raw
    }
    /// Declared charset when it is not UTF-8, for the size label.
    private var charsetLabel: String? {
        guard let charset = BodyText.declaredCharset(contentType: contentType, body: decoded),
              !BodyText.isUTF8(charset) else { return nil }
        return charset
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.headline).lineLimit(1).fixedSize()
                Text(sizeLabel)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !raw.isEmpty {
                    Button("Copy") { Pasteboard.copy(copyText) }
                        .buttonStyle(.link)
                        .font(.caption)
                    Picker("Mode", selection: $mode) {
                        ForEach(availableModes) { m in Text(m.title).tag(m) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.mini)
                    .fixedSize()
                    .onChange(of: mode) { _, new in model.preferredBodyMode = new }
                }
            }
            if decodeFailed {
                Label("Could not decode Content-Encoding “\(encoding ?? "")” — showing raw bytes.",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if raw.isEmpty {
                Text("Empty body").font(.callout).foregroundStyle(.secondary)
            } else {
                switch mode {
                case .pretty: prettyView
                case .raw: codeBox(Text(BodyPresentation.rawText(decoded, contentType: contentType,
                                                                 limit: BodyPresentation.maxRawBytes)))
                case .preview: previewView
                case .hex: codeBox(Text(HexDump.render(decoded)))
                }
            }
        }
        .onChange(of: cacheKey, initial: true) { _, _ in
            pretty = BodyPresentation.prettyText(decoded, category: category, contentType: contentType)
            mode = defaultMode
            scheduleHighlight()
        }
        .onChange(of: model.preferredBodyMode) { _, _ in
            mode = defaultMode
        }
    }

    /// The remembered mode when it applies to this body, else a sensible automatic choice.
    private var defaultMode: BodyMode {
        if let preferred = model.preferredBodyMode, availableModes.contains(preferred) { return preferred }
        if category == .image { return .preview }
        if category == .pdf || category == .binary { return .hex }
        if canPretty { return .pretty }
        return BodyPresentation.looksTextual(decoded) ? .raw : .hex
    }

    private var cacheKey: Int {
        var h = Hasher()
        h.combine(decoded.count)
        h.combine(category)
        h.combine(decoded.prefix(256))
        h.combine(decoded.suffix(64))
        return h.finalize()
    }

    private var sizeLabel: String {
        var label = Format.bytes(raw.count)
        if let encoding, !decodeFailed, encoding.lowercased() != "identity" {
            label = "\(Format.bytes(decoded.count)) · \(encoding) \(Format.bytes(raw.count))"
        }
        if let charsetLabel { label += " · \(charsetLabel)" }
        return label
    }

    private var copyText: String {
        switch mode {
        case .pretty: return pretty ?? BodyPresentation.rawText(decoded, contentType: contentType)
        case .hex: return HexDump.render(decoded)
        default: return BodyPresentation.rawText(decoded, contentType: contentType)
        }
    }

    @ViewBuilder
    private var prettyView: some View {
        if let highlighted {
            codeBox(Text(highlighted))
        } else if let pretty {
            codeBox(Text(BodyPresentation.truncatedForDisplay(pretty)))
        } else {
            codeBox(Text(BodyPresentation.rawText(decoded, contentType: contentType,
                                                  limit: BodyPresentation.maxRawBytes)))
        }
    }

    @ViewBuilder
    private var previewView: some View {
        switch category {
        case .image:
            if let image = NSImage(data: decoded) {
                VStack(alignment: .leading, spacing: 4) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: max(image.size.width, 16), maxHeight: min(max(image.size.height, 16), 480))
                        .background(CheckerboardBackground())
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    Text("\(Int(image.size.width)) × \(Int(image.size.height)) pt · \(Format.bytes(decoded.count))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Image could not be decoded.").font(.callout).foregroundStyle(.secondary)
            }
        case .html:
            HTMLPreview(html: BodyPresentation.rawText(decoded, contentType: contentType), baseURL: baseURL)
                .frame(minHeight: 320, maxHeight: 600)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        default:
            Text("No preview for this content type.").font(.callout).foregroundStyle(.secondary)
        }
    }

    private func codeBox(_ text: Text) -> some View {
        text
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func scheduleHighlight() {
        highlighted = nil
        let key = cacheKey
        highlightKey = key
        guard let text = pretty, text.utf8.count <= SyntaxHighlighter.maxHighlightBytes else { return }
        let cat = category
        Task.detached(priority: .userInitiated) {
            let result = SyntaxHighlighter.highlight(text, category: cat)
            await MainActor.run {
                if highlightKey == key { highlighted = result }
            }
        }
    }
}

/// Transparent-checkerboard behind image previews.
struct CheckerboardBackground: View {
    var body: some View {
        Canvas { context, size in
            let cell: CGFloat = 8
            var y: CGFloat = 0
            while y < size.height {
                var x: CGFloat = 0
                while x < size.width {
                    let dark = (Int(x / cell) + Int(y / cell)).isMultiple(of: 2)
                    context.fill(Path(CGRect(x: x, y: y, width: cell, height: cell)),
                                 with: .color(dark ? Color.gray.opacity(0.18) : Color.gray.opacity(0.06)))
                    x += cell
                }
                y += cell
            }
        }
    }
}

/// Sandboxed HTML preview (JavaScript disabled). Resources load directly, not via the proxy.
struct HTMLPreview: NSViewRepresentable {
    let html: String
    let baseURL: URL?

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastHTML != html {
            context.coordinator.lastHTML = html
            view.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var lastHTML: String? }
}

// MARK: - Presentation helpers

enum BodyPresentation {
    /// Text suitable for the Pretty tab, or nil when the body is not textual.
    /// `contentType` supplies the charset (EUC-KR, Shift_JIS, …); UTF-8 otherwise.
    static func prettyText(_ data: Data, category: ContentCategory, contentType: String? = nil) -> String? {
        if category == .image || category == .pdf || category == .binary { return nil }
        if data.count > maxPrettyBytes { return nil }
        guard let text = BodyText.decode(data, contentType: contentType) else { return nil }
        let utf8 = Data(text.utf8)
        if category == .json || looksLikeJSON(utf8) {
            if let obj = try? JSONSerialization.jsonObject(with: utf8, options: [.fragmentsAllowed]),
               let pretty = try? JSONSerialization.data(withJSONObject: obj,
                                                        options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
               let s = String(data: pretty, encoding: .utf8) {
                return s
            }
        }
        if category == .form {
            return text.split(separator: "&").map { pair -> String in
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                let key = parts.first?.removingPercentEncoding ?? String(pair)
                let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
                return "\(key) = \(value)"
            }.joined(separator: "\n")
        }
        if category == .other && !looksTextual(utf8) { return nil }
        return text
    }

    /// Bodies above this size skip pretty-printing; Raw / Hex still show them.
    static let maxPrettyBytes = 4 * 1024 * 1024
    /// Bytes the Raw tab lays out. A single SwiftUI `Text` with megabytes of
    /// characters freezes the main thread, so the rest is summarised.
    static let maxRawBytes = 64 * 1024

    /// Lossy text rendering for the Raw tab, honouring the declared charset.
    /// With `limit`, only the first `limit` bytes are rendered, followed by a
    /// note of how much was left out.
    static func rawText(_ data: Data, contentType: String? = nil, limit: Int? = nil) -> String {
        guard let limit, data.count > limit else {
            return BodyText.lossyDecode(data, contentType: contentType)
        }
        return BodyText.lossyDecode(data.prefix(limit), contentType: contentType)
            + omissionNote(bytesLeft: data.count - limit)
    }

    /// The first `maxRawBytes` of already-decoded text, for the Pretty tab
    /// when the body was too large to highlight.
    static func truncatedForDisplay(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > maxRawBytes else { return text }
        let cut = String(decoding: utf8.prefix(maxRawBytes), as: UTF8.self)
        return cut + omissionNote(bytesLeft: utf8.count - maxRawBytes)
    }

    private static func omissionNote(bytesLeft: Int) -> String {
        "\n… \(Format.bytes(bytesLeft)) more not shown (Copy gives the full body)"
    }

    static func prettyJSONIfPossible(_ text: String) -> String {
        let data = Data(text.utf8)
        guard looksLikeJSON(data) else { return text }
        return prettyText(data, category: .json) ?? text
    }

    static func looksLikeJSON(_ data: Data) -> Bool {
        guard let first = data.first(where: { !$0.isWhitespaceByte }) else { return false }
        return first == UInt8(ascii: "{") || first == UInt8(ascii: "[")
    }

    /// Heuristic: no NUL bytes and mostly printable in the first 1 KiB.
    static func looksTextual(_ data: Data) -> Bool {
        let sample = data.prefix(1024)
        guard !sample.isEmpty else { return true }
        var control = 0
        for b in sample {
            if b == 0 { return false }
            if b < 0x20 && b != 0x09 && b != 0x0A && b != 0x0D { control += 1 }
        }
        return control * 20 < sample.count
    }
}

extension UInt8 {
    var isWhitespaceByte: Bool {
        self == 0x20 || self == 0x09 || self == 0x0A || self == 0x0D
    }
}

/// Classic `xxd`-style hex dump, capped for very large bodies.
enum HexDump {
    static let maxBytes = 16 * 1024

    static func render(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(maxBytes))
        var out = ""
        out.reserveCapacity(bytes.count * 4)
        let hexDigits = Array("0123456789abcdef".utf8)
        var offset = 0
        while offset < bytes.count {
            let line = bytes[offset..<min(offset + 16, bytes.count)]
            out += String(format: "%08x  ", offset)
            var hex = [UInt8]()
            var ascii = [UInt8]()
            for (i, b) in line.enumerated() {
                hex.append(hexDigits[Int(b >> 4)])
                hex.append(hexDigits[Int(b & 0x0f)])
                hex.append(0x20)
                if i == 7 { hex.append(0x20) }
                ascii.append((0x20...0x7e).contains(b) ? b : UInt8(ascii: "."))
            }
            let padding = (16 - line.count) * 3 + (line.count <= 8 ? 1 : 0)
            out += String(decoding: hex, as: UTF8.self)
            out += String(repeating: " ", count: max(0, padding))
            out += " |" + String(decoding: ascii, as: UTF8.self) + "|\n"
            offset += 16
        }
        if data.count > maxBytes {
            out += "… \(Format.bytes(data.count - maxBytes)) more not shown"
        }
        return out
    }
}

// MARK: - Syntax highlighting

/// Lightweight tokeniser → `AttributedString` for JSON, XML/HTML, JS and CSS.
enum SyntaxHighlighter {
    /// Bodies larger than this are shown as plain text (keeps the UI responsive).
    static let maxHighlightBytes = 512 * 1024

    enum Token { case plain, key, string, number, keyword, tag, attribute, comment, punctuation }

    static func highlight(_ text: String, category: ContentCategory) -> AttributedString {
        let bytes = Array(text.utf8)
        let runs: [(Range<Int>, Token)]
        switch category {
        case .json: runs = tokenizeJSON(bytes)
        case .xml, .html: runs = tokenizeMarkup(bytes)
        case .javascript, .css: runs = tokenizeCLike(bytes)
        default: return AttributedString(text)
        }
        var result = AttributedString()
        for (range, token) in runs {
            var piece = AttributedString(String(decoding: bytes[range], as: UTF8.self))
            if let color = color(for: token) { piece.foregroundColor = color }
            result.append(piece)
        }
        return result
    }

    static func color(for token: Token) -> Color? {
        switch token {
        case .plain, .punctuation: return nil
        case .key: return Color(nsColor: .systemIndigo)
        case .string: return Color(nsColor: .systemRed)
        case .number: return Color(nsColor: .systemBlue)
        case .keyword: return Color(nsColor: .systemPurple)
        case .tag: return Color(nsColor: .systemBlue)
        case .attribute: return Color(nsColor: .systemTeal)
        case .comment: return Color(nsColor: .secondaryLabelColor)
        }
    }

    // MARK: JSON

    static func tokenizeJSON(_ b: [UInt8]) -> [(Range<Int>, Token)] {
        var runs: [(Range<Int>, Token)] = []
        var i = 0
        var plainStart = 0
        func flushPlain(_ upTo: Int) {
            if upTo > plainStart { runs.append((plainStart..<upTo, .plain)) }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "\"") {
                flushPlain(i)
                let start = i
                i += 1
                while i < b.count {
                    if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if b[i] == UInt8(ascii: "\"") { i += 1; break }
                    i += 1
                }
                let end = min(i, b.count)
                var j = end
                while j < b.count && b[j].isWhitespaceByte { j += 1 }
                let isKey = j < b.count && b[j] == UInt8(ascii: ":")
                runs.append((start..<end, isKey ? .key : .string))
                plainStart = end
            } else if c == UInt8(ascii: "-") || (c >= 0x30 && c <= 0x39) {
                flushPlain(i)
                let start = i
                i += 1
                while i < b.count, isNumberByte(b[i]) { i += 1 }
                runs.append((start..<i, .number))
                plainStart = i
            } else if c == UInt8(ascii: "t") || c == UInt8(ascii: "f") || c == UInt8(ascii: "n") {
                flushPlain(i)
                let start = i
                while i < b.count, (b[i] >= 0x61 && b[i] <= 0x7a) { i += 1 }
                runs.append((start..<i, .keyword))
                plainStart = i
            } else {
                i += 1
            }
        }
        flushPlain(b.count)
        return runs
    }

    private static func isNumberByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ".") || c == UInt8(ascii: "e") || c == UInt8(ascii: "E")
            || c == UInt8(ascii: "+") || c == UInt8(ascii: "-")
    }

    // MARK: XML / HTML

    static func tokenizeMarkup(_ b: [UInt8]) -> [(Range<Int>, Token)] {
        var runs: [(Range<Int>, Token)] = []
        var i = 0
        var plainStart = 0
        func flushPlain(_ upTo: Int) {
            if upTo > plainStart { runs.append((plainStart..<upTo, .plain)) }
        }
        func starts(_ s: String, at index: Int) -> Bool {
            let u = Array(s.utf8)
            guard index + u.count <= b.count else { return false }
            for k in 0..<u.count where b[index + k] != u[k] { return false }
            return true
        }
        func find(_ s: String, from index: Int) -> Int? {
            let u = Array(s.utf8)
            var k = index
            while k + u.count <= b.count {
                if starts(s, at: k) { return k }
                k += 1
            }
            return nil
        }
        while i < b.count {
            guard b[i] == UInt8(ascii: "<") else { i += 1; continue }
            flushPlain(i)
            if starts("<!--", at: i) {
                let end = find("-->", from: i + 4).map { $0 + 3 } ?? b.count
                runs.append((i..<end, .comment))
                i = end; plainStart = i
                continue
            }
            // Tag: `<` [/] name (attrs)* [/] `>`
            var j = i + 1
            if j < b.count && b[j] == UInt8(ascii: "/") { j += 1 }
            let nameStart = j
            while j < b.count, !b[j].isWhitespaceByte, b[j] != UInt8(ascii: ">"), b[j] != UInt8(ascii: "/") { j += 1 }
            runs.append((i..<nameStart, .punctuation))
            runs.append((nameStart..<j, .tag))
            // attributes
            while j < b.count && b[j] != UInt8(ascii: ">") {
                if b[j].isWhitespaceByte || b[j] == UInt8(ascii: "/") || b[j] == UInt8(ascii: "=") {
                    runs.append((j..<(j + 1), .punctuation)); j += 1; continue
                }
                if b[j] == UInt8(ascii: "\"") || b[j] == UInt8(ascii: "'") {
                    let quote = b[j]
                    let start = j
                    j += 1
                    while j < b.count && b[j] != quote { j += 1 }
                    j = min(j + 1, b.count)
                    runs.append((start..<j, .string))
                    continue
                }
                let start = j
                while j < b.count, !b[j].isWhitespaceByte, b[j] != UInt8(ascii: "="), b[j] != UInt8(ascii: ">"),
                      b[j] != UInt8(ascii: "/") { j += 1 }
                runs.append((start..<j, .attribute))
            }
            if j < b.count { runs.append((j..<(j + 1), .punctuation)); j += 1 }
            i = j; plainStart = i
            // Skip raw-text elements so their contents aren't parsed as markup.
            let tagName = String(decoding: b[nameStart..<min(nameStart + 6, b.count)], as: UTF8.self).lowercased()
            if tagName.hasPrefix("script") || tagName.hasPrefix("style") {
                let closer = tagName.hasPrefix("script") ? "</script" : "</style"
                let end = find(closer, from: i) ?? b.count
                let inner = tokenizeCLike(Array(b[i..<end]))
                for (r, t) in inner { runs.append(((r.lowerBound + i)..<(r.upperBound + i), t)) }
                i = end; plainStart = i
            }
        }
        flushPlain(b.count)
        return runs
    }

    // MARK: JS / CSS (strings, comments, numbers)

    static func tokenizeCLike(_ b: [UInt8]) -> [(Range<Int>, Token)] {
        var runs: [(Range<Int>, Token)] = []
        var i = 0
        var plainStart = 0
        func flushPlain(_ upTo: Int) {
            if upTo > plainStart { runs.append((plainStart..<upTo, .plain)) }
        }
        while i < b.count {
            let c = b[i]
            if c == UInt8(ascii: "/") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "/") {
                flushPlain(i)
                let start = i
                while i < b.count && b[i] != 0x0A { i += 1 }
                runs.append((start..<i, .comment)); plainStart = i
            } else if c == UInt8(ascii: "/") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "*") {
                flushPlain(i)
                let start = i
                i += 2
                while i + 1 < b.count && !(b[i] == UInt8(ascii: "*") && b[i + 1] == UInt8(ascii: "/")) { i += 1 }
                i = min(i + 2, b.count)
                runs.append((start..<i, .comment)); plainStart = i
            } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") || c == UInt8(ascii: "`") {
                flushPlain(i)
                let start = i
                i += 1
                while i < b.count {
                    if b[i] == UInt8(ascii: "\\") { i += 2; continue }
                    if b[i] == c || (c != UInt8(ascii: "`") && b[i] == 0x0A) { i += 1; break }
                    i += 1
                }
                i = min(i, b.count)
                runs.append((start..<i, .string)); plainStart = i
            } else if c >= 0x30 && c <= 0x39 && (i == 0 || !isIdentByte(b[i - 1])) {
                flushPlain(i)
                let start = i
                while i < b.count, isNumberByte(b[i]) || isIdentByte(b[i]) { i += 1 }
                runs.append((start..<i, .number)); plainStart = i
            } else {
                i += 1
            }
        }
        flushPlain(b.count)
        return runs
    }

    private static func isIdentByte(_ c: UInt8) -> Bool {
        (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5a) || (c >= 0x61 && c <= 0x7a) || c == UInt8(ascii: "_")
            || c == UInt8(ascii: "$")
    }
}
