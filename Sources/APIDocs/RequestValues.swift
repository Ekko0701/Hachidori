import Foundation

/// What a captured request actually sent, shown beside the documentation of its operation.
public struct RequestValues: Sendable, Equatable {
    /// Values the path gave the template's `{parameters}`.
    public var pathParameters: [String: String]
    /// Query parameters; a name sent more than once keeps every value, in order.
    public var query: [String: [String]]
    /// Request headers by lowercased name.
    public var headers: [String: String]
    public var cookies: [String: String]
    /// The response's status, once it has arrived.
    public var statusCode: Int?

    /// - Parameters:
    ///   - path: The request path with its query string, as sent.
    ///   - headers: The request headers as name and value pairs.
    public init(pathParameters: [String: String], path: String, headers: [(name: String, value: String)],
                statusCode: Int?) {
        self.pathParameters = pathParameters
        self.statusCode = statusCode

        var query: [String: [String]] = [:]
        if let start = path.firstIndex(of: "?") {
            let text = path[path.index(after: start)...].prefix { $0 != "#" }
            for pair in text.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let name = Self.decode(parts[0])
                guard !name.isEmpty else { continue }
                query[name, default: []].append(parts.count > 1 ? Self.decode(parts[1]) : "")
            }
        }
        self.query = query

        var byName: [String: String] = [:]
        var cookies: [String: String] = [:]
        for header in headers {
            let name = header.name.lowercased()
            // A header sent twice reads as one comma-separated value.
            byName[name] = byName[name].map { "\($0), \(header.value)" } ?? header.value
            guard name == "cookie" else { continue }
            for pair in header.value.split(separator: ";") {
                let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let cookie = parts[0].trimmingCharacters(in: .whitespaces)
                guard !cookie.isEmpty else { continue }
                cookies[cookie] = parts.count > 1 ? String(parts[1]) : ""
            }
        }
        self.headers = byName
        self.cookies = cookies
    }

    /// What the request sent for a documented parameter, or nil when it didn't send it.
    public func value(for parameter: Parameter) -> String? {
        switch parameter.location {
        case .path: return pathParameters[parameter.name]
        case .query:
            // Arrays are often sent as `tags[]=a&tags[]=b`.
            let values = query[parameter.name] ?? query[parameter.name + "[]"]
            return values?.joined(separator: ", ")
        case .header: return headers[parameter.name.lowercased()]
        case .cookie: return cookies[parameter.name]
        }
    }

    private static func decode(_ text: Substring) -> String {
        let spaced = text.replacingOccurrences(of: "+", with: " ")
        return spaced.removingPercentEncoding ?? spaced
    }
}
