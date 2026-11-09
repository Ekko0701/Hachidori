import Foundation

/// A response header to set on an overridden response.
public struct HeaderKV: Identifiable, Sendable, Equatable, Hashable, Codable {
    public var id: UUID
    public var name: String
    public var value: String

    public init(id: UUID = UUID(), name: String = "", value: String = "") {
        self.id = id
        self.name = name
        self.value = value
    }
}

/// A user-defined rule that modifies matching responses.
///
/// A rule can either short-circuit (Map Local — return a canned response without
/// contacting the origin) or rewrite the real response (change status / headers /
/// body). Matching is a simple, predictable substring test on the absolute URL.
public struct OverrideRule: Identifiable, Sendable, Equatable, Codable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool

    // Match
    public var methodFilter: String   // "" = any method, else e.g. "GET"
    public var urlContains: String    // "" = match every URL, else case-insensitive substring

    // Behaviour
    public var respondLocally: Bool   // true = don't contact origin (Map Local)

    // Actions
    public var overrideStatus: Bool
    public var statusCode: Int
    public var overrideBody: Bool
    public var body: String
    public var contentType: String    // Content-Type applied when overriding the body
    public var extraHeaders: [HeaderKV]

    public init(id: UUID = UUID(),
                name: String = "New Rule",
                isEnabled: Bool = true,
                methodFilter: String = "",
                urlContains: String = "",
                respondLocally: Bool = false,
                overrideStatus: Bool = false,
                statusCode: Int = 200,
                overrideBody: Bool = false,
                body: String = "",
                contentType: String = "application/json",
                extraHeaders: [HeaderKV] = []) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.methodFilter = methodFilter
        self.urlContains = urlContains
        self.respondLocally = respondLocally
        self.overrideStatus = overrideStatus
        self.statusCode = statusCode
        self.overrideBody = overrideBody
        self.body = body
        self.contentType = contentType
        self.extraHeaders = extraHeaders
    }

    enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, methodFilter, urlContains, respondLocally
        case overrideStatus, statusCode, overrideBody, body, contentType, extraHeaders
    }

    /// Fields missing from a saved rule take their defaults, so rules saved by an
    /// older version still load after new fields are added.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = OverrideRule()
        self.init(id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
                  name: try c.decodeIfPresent(String.self, forKey: .name) ?? d.name,
                  isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled,
                  methodFilter: try c.decodeIfPresent(String.self, forKey: .methodFilter) ?? d.methodFilter,
                  urlContains: try c.decodeIfPresent(String.self, forKey: .urlContains) ?? d.urlContains,
                  respondLocally: try c.decodeIfPresent(Bool.self, forKey: .respondLocally) ?? d.respondLocally,
                  overrideStatus: try c.decodeIfPresent(Bool.self, forKey: .overrideStatus) ?? d.overrideStatus,
                  statusCode: try c.decodeIfPresent(Int.self, forKey: .statusCode) ?? d.statusCode,
                  overrideBody: try c.decodeIfPresent(Bool.self, forKey: .overrideBody) ?? d.overrideBody,
                  body: try c.decodeIfPresent(String.self, forKey: .body) ?? d.body,
                  contentType: try c.decodeIfPresent(String.self, forKey: .contentType) ?? d.contentType,
                  extraHeaders: try c.decodeIfPresent([HeaderKV].self, forKey: .extraHeaders) ?? d.extraHeaders)
    }

    public func matches(method: String, url: String) -> Bool {
        guard isEnabled else { return false }
        if !methodFilter.isEmpty, methodFilter.uppercased() != method.uppercased() { return false }
        if !urlContains.isEmpty, !url.lowercased().contains(urlContains.lowercased()) { return false }
        return true
    }
}

/// Thread-safe snapshot of the active override rules, read by the proxy engine
/// on every request and updated by the UI.
public final class RuleStore: @unchecked Sendable {
    private let lock = NSLock()
    private var rules: [OverrideRule] = []

    public init() {}

    public func setRules(_ rules: [OverrideRule]) {
        lock.lock(); self.rules = rules; lock.unlock()
    }

    public var hasEnabledRules: Bool {
        lock.lock(); defer { lock.unlock() }
        return rules.contains { $0.isEnabled }
    }

    /// The first enabled rule matching the request, if any.
    public func firstMatch(method: String, url: String) -> OverrideRule? {
        lock.lock(); defer { lock.unlock() }
        return rules.first { $0.matches(method: method, url: url) }
    }
}
