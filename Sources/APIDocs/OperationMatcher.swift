import Foundation

/// A captured request matched to the operation that documents it.
public struct OperationMatch: Sendable {
    public let operation: APIOperation
    /// What the request's path gave each `{parameter}` in the template, percent-decoded.
    public let pathParameters: [String: String]
}

/// Finds the operation in one document that a captured request belongs to.
///
/// A request matches when its host is one the document applies to, its path starts
/// with one of the document's base paths, and the rest fits an operation's path
/// template with the same method. When several templates fit, the most literal one
/// wins: `/users/me` over `/users/{id}`, as the OpenAPI specification asks.
public struct OperationMatcher: Sendable {
    /// Hosts the document applies to: `api.example.com`, `localhost:8080` (that port only)
    /// or `*.example.com`. Empty means any host.
    public let hosts: [String]
    /// Path prefixes in front of the document's paths, longest first. `""` is no prefix.
    public let basePaths: [String]
    /// Templates grouped by how many segments they have and by their first segment when
    /// it is literal, so a request is only compared with the few that could fit it.
    private let templates: [Bucket: [Template]]

    private struct Bucket: Hashable, Sendable {
        let segmentCount: Int
        /// Nil when the first segment is a parameter, or there are no segments.
        let firstLiteral: String?
    }

    /// - Parameters:
    ///   - hosts: Hosts to match instead of the ones in the document's `servers`. Documents
    ///     often list only production, while the traffic goes to a development server.
    ///   - basePaths: Path prefixes to use instead of the ones in `servers`.
    public init(document: APIDocument, hosts: [String]? = nil, basePaths: [String]? = nil) {
        let hostList = hosts ?? document.servers.compactMap(\.host)
        self.hosts = Self.unique(hostList.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty })

        var bases = Self.unique((basePaths ?? document.servers.map(\.basePath)).map(Self.normalizedBasePath))
        if bases.isEmpty { bases = [""] }
        self.basePaths = bases.sorted { $0.count > $1.count }

        var templates: [Bucket: [Template]] = [:]
        for operation in document.operations {
            let template = Template(operation: operation)
            var firstLiteral: String?
            if let first = template.segments.first, first.count == 1, case .literal(let literal) = first[0] {
                firstLiteral = literal
            }
            templates[Bucket(segmentCount: template.segments.count, firstLiteral: firstLiteral), default: []]
                .append(template)
        }
        self.templates = templates
    }

    /// Whether the document applies to requests sent to `host`.
    public func applies(toHost host: String, port: Int? = nil) -> Bool {
        if hosts.isEmpty { return true }
        let host = host.lowercased()
        return hosts.contains { entry in
            var name = Substring(entry)
            if let colon = entry.lastIndex(of: ":"), let entryPort = Int(entry[entry.index(after: colon)...]) {
                if let port, port != entryPort { return false }
                name = entry[..<colon]
            }
            if name.hasPrefix("*.") { return host.hasSuffix(name.dropFirst()) }
            return host == name
        }
    }

    /// The operation documenting a request, or nil when the document doesn't cover it.
    /// `path` may carry a query string; it is ignored.
    public func match(method: String, host: String, port: Int? = nil, path: String) -> OperationMatch? {
        guard applies(toHost: host, port: port) else { return nil }
        let method = method.uppercased()
        let path = String(path.prefix { $0 != "?" && $0 != "#" })

        for base in basePaths {
            guard base.isEmpty || path == base || path.hasPrefix(base + "/") else { continue }
            let raw = path.dropFirst(base.count).split(separator: "/").map(String.init)
            let decoded = raw.map { $0.removingPercentEncoding ?? $0 }

            var buckets = [Bucket(segmentCount: raw.count, firstLiteral: nil)]
            if let first = decoded.first {
                buckets.append(Bucket(segmentCount: raw.count, firstLiteral: first))
                if raw[0] != first { buckets.append(Bucket(segmentCount: raw.count, firstLiteral: raw[0])) }
            }

            var best: (template: Template, parameters: [String: String])?
            for bucket in buckets {
                for template in templates[bucket] ?? [] where template.operation.method == method {
                    guard let parameters = template.match(raw: raw, decoded: decoded) else { continue }
                    if let current = best, !current.template.rank.lexicographicallyPrecedes(template.rank) { continue }
                    best = (template, parameters)
                }
            }
            if let best {
                return OperationMatch(operation: best.template.operation, pathParameters: best.parameters)
            }
        }
        return nil
    }

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { seen.insert($0).inserted }
    }

    private static func normalizedBasePath(_ path: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        while path.hasSuffix("/") { path.removeLast() }
        if !path.isEmpty, !path.hasPrefix("/") { path = "/" + path }
        return path
    }
}

/// A path template such as `/users/{id}/files/{name}.json`, split for matching.
private struct Template: Sendable {
    enum Part: Sendable {
        case literal(String)
        case parameter(String)
    }

    let operation: APIOperation
    /// One entry per path segment; a segment is one or more literal and parameter parts.
    let segments: [[Part]]
    /// How literal each segment is (2 literal, 1 mixed, 0 parameter), for picking the most specific match.
    let rank: [Int]

    init(operation: APIOperation) {
        self.operation = operation
        segments = operation.path.split(separator: "/").map { Self.parts(of: String($0)) }
        rank = segments.map { parts in
            if parts.count == 1 {
                if case .literal = parts[0] { return 2 }
                return 0
            }
            return 1
        }
    }

    private static func parts(of segment: String) -> [Part] {
        var parts: [Part] = []
        var rest = Substring(segment)
        while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
            if open > rest.startIndex { parts.append(.literal(String(rest[..<open]))) }
            parts.append(.parameter(String(rest[rest.index(after: open)..<close])))
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty || parts.isEmpty { parts.append(.literal(String(rest))) }
        return parts
    }

    /// The parameter values when `path` fits this template, or nil when it doesn't.
    /// `raw` is the request path's segments as sent, `decoded` the same with percent-escapes resolved.
    func match(raw rawPath: [String], decoded decodedPath: [String]) -> [String: String]? {
        var parameters: [String: String] = [:]
        for (index, parts) in segments.enumerated() {
            let raw = rawPath[index]
            let decoded = decodedPath[index]
            if parts.count == 1 {
                switch parts[0] {
                case .literal(let literal):
                    guard literal == decoded || literal == raw else { return nil }
                case .parameter(let name):
                    parameters[name] = decoded
                }
                continue
            }
            // A mixed segment such as `{name}.json`: each parameter runs up to the next literal.
            var rest = Substring(decoded)
            for (i, part) in parts.enumerated() {
                switch part {
                case .literal(let literal):
                    guard rest.hasPrefix(literal) else { return nil }
                    rest = rest.dropFirst(literal.count)
                case .parameter(let name):
                    var value = rest
                    if i + 1 < parts.count {
                        guard case .literal(let next) = parts[i + 1],
                              let range = rest.dropFirst().range(of: next) else { return nil }
                        value = rest[..<range.lowerBound]
                    }
                    guard !value.isEmpty else { return nil }
                    parameters[name] = String(value)
                    rest = rest[value.endIndex...]
                }
            }
            guard rest.isEmpty else { return nil }
        }
        return parameters
    }
}
