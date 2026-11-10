import Foundation

/// An imported OpenAPI 3.x document, reduced to what Hachidori shows and matches against.
public struct APIDocument: Sendable {
    public var title: String
    public var version: String
    public var description: String?
    /// The document's `openapi` field, such as `3.0.3` or `3.1.0`.
    public var specVersion: String
    public var servers: [Server]
    public var tags: [Tag]
    public var operations: [APIOperation]
    /// Every schema a `$ref` points at, keyed by the reference (`#/components/schemas/User`).
    /// Schemas refer to each other by reference instead of being copied in, so a schema
    /// that contains itself is not a problem.
    public var schemas: [String: Schema]
    /// Things the reader skipped, such as references it could not follow.
    public var warnings: [String]

    public struct Server: Sendable, Equatable {
        /// The URL with any `{variables}` replaced by their defaults.
        public var url: String
        public var description: String?

        /// Host, with the port when the URL names one. Nil for a relative URL such as `/v1`.
        public var host: String? {
            guard let components = URLComponents(string: url), let host = components.host, !host.isEmpty else { return nil }
            return (components.port.map { "\(host):\($0)" } ?? host).lowercased()
        }

        /// The path every operation sits under, without a trailing slash (`/v1`, or empty).
        public var basePath: String {
            guard let components = URLComponents(string: url),
                  components.host != nil || url.hasPrefix("/") else { return "" }
            var path = components.path
            while path.hasSuffix("/") { path.removeLast() }
            return path
        }
    }

    public struct Tag: Sendable, Equatable {
        public var name: String
        public var description: String?
    }

    /// The schema a reference points at, following chains of references.
    /// Returns the schema unchanged when it is not a reference or the target is missing.
    public func resolved(_ schema: Schema) -> Schema {
        var current = schema
        var seen: Set<String> = []
        while let reference = current.reference, seen.insert(reference).inserted,
              let target = schemas[reference] {
            current = target
        }
        return current
    }
}

/// One method on one path, such as `GET /users/{id}`.
public struct APIOperation: Sendable, Identifiable {
    /// `GET /users/{id}`: unique within a document.
    public var id: String { "\(method) \(path)" }
    /// Uppercase HTTP method.
    public var method: String
    /// The path template as written, such as `/users/{id}`.
    public var path: String
    public var operationID: String?
    public var summary: String?
    public var description: String?
    public var tags: [String]
    public var isDeprecated: Bool
    /// Path-level and operation-level parameters; the operation's win on a clash.
    public var parameters: [Parameter]
    public var requestBody: RequestBody?
    public var responses: [Response]

    /// The response documented for `status`: the exact code, then a range such as `4XX`, then `default`.
    public func response(forStatus status: Int) -> Response? {
        let exact = String(status)
        let range = "\(status / 100)XX"
        return responses.first { $0.status == exact }
            ?? responses.first { $0.status.uppercased() == range }
            ?? responses.first { $0.status == "default" }
    }
}

public struct Parameter: Sendable {
    public enum Location: String, Sendable {
        case path, query, header, cookie
    }

    public var name: String
    public var location: Location
    public var isRequired: Bool
    public var isDeprecated: Bool
    public var description: String?
    public var schema: Schema?
    public var example: DocValue?
}

public struct RequestBody: Sendable {
    public var description: String?
    public var isRequired: Bool
    public var content: [MediaType]
}

/// The body for one content type, such as `application/json`.
public struct MediaType: Sendable {
    public var contentType: String
    public var schema: Schema?
    public var examples: [Example]
}

public struct Example: Sendable {
    /// Nil for the single unnamed `example`.
    public var name: String?
    public var summary: String?
    public var value: DocValue
}

public struct Response: Sendable {
    /// `200`, a range such as `4XX`, or `default`.
    public var status: String
    public var description: String?
    public var headers: [Header]
    public var content: [MediaType]

    public struct Header: Sendable {
        public var name: String
        public var description: String?
        public var isRequired: Bool
        public var schema: Schema?
    }
}

/// A JSON Schema as OpenAPI uses it. Either a reference to another schema
/// (`reference` is set; look it up with `APIDocument.resolved`) or an inline definition.
public struct Schema: Sendable {
    /// `#/components/schemas/User` when this stands for another schema.
    public var reference: String?
    /// The component name (`User`) when this schema is a named one.
    public var name: String?

    /// `string`, `object`, ... Empty when the schema does not say. `null` is reported through `isNullable`.
    public var types: [String] = []
    public var format: String?
    public var title: String?
    public var description: String?
    public var isNullable = false
    public var isDeprecated = false
    public var isReadOnly = false
    public var isWriteOnly = false

    public var properties: [Property] = []
    /// Whether keys beyond `properties` are allowed, when the schema says.
    public var allowsAdditionalProperties: Bool?
    public var enumValues: [DocValue] = []
    public var constValue: DocValue?
    public var defaultValue: DocValue?
    public var example: DocValue?

    public var allOf: [Schema] = []
    public var oneOf: [Schema] = []
    public var anyOf: [Schema] = []
    public var discriminatorProperty: String?

    public var minimum: Double?
    public var maximum: Double?
    public var minLength: Int?
    public var maxLength: Int?
    public var minItems: Int?
    public var maxItems: Int?
    public var pattern: String?

    // A struct cannot hold itself directly; a one-element array gives the indirection.
    private var itemsStorage: [Schema] = []
    private var additionalPropertiesStorage: [Schema] = []

    /// The schema of each element, for arrays.
    public var items: Schema? {
        get { itemsStorage.first }
        set { itemsStorage = newValue.map { [$0] } ?? [] }
    }

    /// The schema of values under keys not listed in `properties`.
    public var additionalProperties: Schema? {
        get { additionalPropertiesStorage.first }
        set { additionalPropertiesStorage = newValue.map { [$0] } ?? [] }
    }

    public struct Property: Sendable {
        public var name: String
        public var schema: Schema
        public var isRequired: Bool
    }

    public init() {}

    /// The last part of a reference: `User` for `#/components/schemas/User`.
    public var referenceName: String? {
        reference.flatMap { $0.split(separator: "/").last }.map(String.init)
    }
}

public enum APIDocError: LocalizedError, Equatable {
    case notText
    case syntax(String)
    case notOpenAPI
    case unsupportedVersion(String)

    public var errorDescription: String? {
        switch self {
        case .notText: "The file isn't UTF-8 text."
        case .syntax(let detail): "The file isn't valid YAML or JSON. \(detail)"
        case .notOpenAPI: "The file isn't an OpenAPI document: it has no \"openapi\" field."
        case .unsupportedVersion(let version): "\(version) documents aren't supported. Hachidori reads OpenAPI 3.0 and 3.1."
        }
    }
}
