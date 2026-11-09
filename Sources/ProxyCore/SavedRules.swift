import Foundation

/// The rules and breakpoint settings kept between launches.
///
/// The breakpoint switches themselves are deliberately not saved: a launch that
/// starts pausing traffic before the user asked for it looks like a hang.
public struct SavedRules: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var rules: [OverrideRule]
    public var breakpointURLContains: String

    public init(rules: [OverrideRule] = [], breakpointURLContains: String = "") {
        self.version = Self.currentVersion
        self.rules = rules
        self.breakpointURLContains = breakpointURLContains
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        rules = try c.decodeIfPresent([OverrideRule].self, forKey: .rules) ?? []
        breakpointURLContains = try c.decodeIfPresent(String.self, forKey: .breakpointURLContains) ?? ""
    }
}

/// Reads and writes `SavedRules` as JSON, readable only by the owner.
public struct SavedRulesFile: Sendable {
    public enum LoadResult: Equatable, Sendable {
        /// No file yet (first launch).
        case none
        case loaded(SavedRules)
        /// The file could not be read. It was moved to `movedTo` so a later save
        /// does not overwrite what the user had.
        case unreadable(movedTo: URL)
    }

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public var corruptURL: URL {
        url.deletingPathExtension().appendingPathExtension("corrupt.json")
    }

    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: url) else { return .none }
        if let saved = try? JSONDecoder().decode(SavedRules.self, from: data) {
            return .loaded(saved)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: corruptURL)
        try? fm.moveItem(at: url, to: corruptURL)
        return .unreadable(movedTo: corruptURL)
    }

    public func save(_ saved: SavedRules) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(saved)
        let fm = FileManager.default
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        // Mock bodies and headers can hold tokens, so keep the file owner-only like the CA key.
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
