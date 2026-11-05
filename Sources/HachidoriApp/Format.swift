import SwiftUI
import ProxyCore

/// Display formatting shared across the UI.
enum Format {
    static func bytes(_ count: Int) -> String {
        if count == 0 { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .binary)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 0.001 { return "<1 ms" }
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 10 { return String(format: "%.2f s", seconds) }
        return String(format: "%.1f s", seconds)
    }

    /// Precise millisecond rendering for the timing tab.
    static func milliseconds(_ seconds: TimeInterval) -> String {
        let ms = seconds * 1000
        if ms < 1 { return String(format: "%.2f ms", ms) }
        if ms < 100 { return String(format: "%.1f ms", ms) }
        return String(format: "%.0f ms", ms)
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static let fullFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func clock(_ date: Date) -> String { clockFormatter.string(from: date) }
    static func fullTimestamp(_ date: Date) -> String { fullFormatter.string(from: date) }

    // MARK: colours

    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .blue
        case "POST": return .green
        case "PUT": return .orange
        case "PATCH": return Color(nsColor: .systemYellow)
        case "DELETE": return .red
        case "HEAD": return .teal
        case "OPTIONS": return .indigo
        case "CONNECT": return .purple
        default: return .gray
        }
    }

    static func statusColor(code: Int?, error: String?) -> Color {
        if error != nil && code == nil { return .red }
        guard let code else { return .secondary }
        switch code {
        case 100..<200: return .purple
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    static func durationColor(_ seconds: TimeInterval) -> Color {
        if seconds >= 2 { return .red }
        if seconds >= 0.5 { return .orange }
        return .secondary
    }

    static func categoryColor(_ category: ContentCategory) -> Color {
        switch category {
        case .json: return .orange
        case .html: return .blue
        case .xml: return .indigo
        case .javascript: return Color(nsColor: .systemYellow)
        case .css: return .purple
        case .image: return .green
        case .form: return .teal
        case .text: return .secondary
        case .pdf: return .red
        case .binary: return .gray
        case .other: return .secondary
        }
    }
}
