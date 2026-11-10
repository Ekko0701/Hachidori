import Foundation

/// Reads an OpenAPI 3.0 or 3.1 document from YAML or JSON.
///
/// The reader is lenient: real documents often break the specification in small ways,
/// so anything it can't use is skipped and noted in `APIDocument.warnings` instead of
/// failing the import.
public enum APIDocumentParser {
    public static func parse(_ data: Data) throws -> APIDocument {
        var bytes = data
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { bytes = Data(bytes.dropFirst(3)) }
        guard let text = String(data: bytes, encoding: .utf8) else { throw APIDocError.notText }
        return try parse(text: text)
    }

    public static func parse(text: String) throws -> APIDocument {
        let root = try DocValue.parse(text: text)
        guard root.object != nil else { throw APIDocError.notOpenAPI }
        if let swagger = root["swagger"] {
            throw APIDocError.unsupportedVersion("Swagger \(swagger.string ?? swagger.jsonText())")
        }
        guard let versionValue = root["openapi"] else { throw APIDocError.notOpenAPI }
        // An unquoted `openapi: 3.0` is a number in YAML.
        let specVersion = versionValue.string ?? versionValue.jsonText()
        guard specVersion.hasPrefix("3.") else {
            throw APIDocError.unsupportedVersion("OpenAPI \(specVersion)")
        }
        var builder = Builder(root: root)
        return builder.document(specVersion: specVersion)
    }
}

private struct Builder {
    let root: DocValue
    var schemas: [String: Schema] = [:]
    /// Schema references seen but not read yet.
    var pending: [String] = []
    var queued: Set<String> = []
    var warnings: [String] = []
    var warned: Set<String> = []

    private static let methods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

    init(root: DocValue) {
        self.root = root
    }

    mutating func document(specVersion: String) -> APIDocument {
        let info = root["info"]
        var tags: [APIDocument.Tag] = []
        for value in root["tags"]?.array ?? [] {
            guard let name = value["name"]?.string else { continue }
            tags.append(.init(name: name, description: value["description"]?.string))
        }

        var operations: [APIOperation] = []
        for entry in root["paths"]?.object?.entries ?? [] where entry.key.hasPrefix("/") {
            guard let item = deref(entry.value), let itemObject = item.object else { continue }
            let shared = parameters(from: item["parameters"])
            for member in itemObject.entries where Self.methods.contains(member.key.lowercased()) {
                guard member.value.object != nil else { continue }
                operations.append(operation(method: member.key.uppercased(), path: entry.key,
                                            value: member.value, pathParameters: shared))
            }
        }
        readPendingSchemas()

        let version = info?["version"]
        return APIDocument(title: info?["title"]?.string ?? "Untitled API",
                           version: version?.string ?? version?.jsonText() ?? "",
                           description: info?["description"]?.string,
                           specVersion: specVersion,
                           servers: servers(from: root["servers"]),
                           tags: tags,
                           operations: operations,
                           schemas: schemas,
                           warnings: warnings)
    }

    // MARK: references

    mutating func warn(_ message: String) {
        if warned.insert(message).inserted { warnings.append(message) }
    }

    /// The value a `$ref` names, following chains. Nil, with a warning, when it can't be followed.
    mutating func deref(_ value: DocValue) -> DocValue? {
        var current = value
        for _ in 0..<16 {
            guard let reference = current["$ref"]?.string else { return current }
            guard let target = lookup(reference) else { return nil }
            current = target
        }
        warn("Gave up on a reference that keeps pointing at other references.")
        return nil
    }

    /// Follows a JSON pointer such as `#/components/schemas/User` from the document root.
    mutating func lookup(_ reference: String) -> DocValue? {
        guard reference.hasPrefix("#") else {
            warn("Skipped a reference to another file: \(reference)")
            return nil
        }
        var current = root
        for token in reference.dropFirst().split(separator: "/") {
            let key = (String(token).removingPercentEncoding ?? String(token))
                .replacingOccurrences(of: "~1", with: "/")
                .replacingOccurrences(of: "~0", with: "~")
            if let next = current[key] {
                current = next
            } else if let items = current.array, let index = Int(key), items.indices.contains(index) {
                current = items[index]
            } else {
                warn("Couldn't find \(reference)")
                return nil
            }
        }
        return current
    }

    /// Reads every schema that a reference pointed at, and the ones those point at in turn.
    mutating func readPendingSchemas() {
        while let reference = pending.popLast() {
            guard schemas[reference] == nil, let target = lookup(reference),
                  var schema = schema(from: target) else { continue }
            if schema.reference == nil {
                schema.name = reference.split(separator: "/").last.map(String.init)
            }
            schemas[reference] = schema
        }
    }

    // MARK: pieces

    func servers(from value: DocValue?) -> [APIDocument.Server] {
        var servers: [APIDocument.Server] = []
        for value in value?.array ?? [] {
            guard var url = value["url"]?.string else { continue }
            for variable in value["variables"]?.object?.entries ?? [] {
                guard let fallback = variable.value["default"] else { continue }
                url = url.replacingOccurrences(of: "{\(variable.key)}", with: fallback.string ?? fallback.jsonText())
            }
            servers.append(.init(url: url, description: value["description"]?.string))
        }
        return servers
    }

    mutating func operation(method: String, path: String, value: DocValue, pathParameters: [Parameter]) -> APIOperation {
        let own = parameters(from: value["parameters"])
        // The operation's parameter replaces a path-level one with the same name and place.
        let inherited = pathParameters.filter { shared in
            !own.contains { $0.name == shared.name && $0.location == shared.location }
        }

        var requestBody: RequestBody?
        if let raw = value["requestBody"], let body = deref(raw) {
            requestBody = RequestBody(description: body["description"]?.string,
                                      isRequired: body["required"]?.bool ?? false,
                                      content: content(from: body["content"]))
        }

        var responses: [Response] = []
        for entry in value["responses"]?.object?.entries ?? [] {
            guard let response = deref(entry.value) else { continue }
            var headers: [Response.Header] = []
            for header in response["headers"]?.object?.entries ?? [] {
                guard let definition = deref(header.value) else { continue }
                headers.append(.init(name: header.key,
                                     description: definition["description"]?.string,
                                     isRequired: definition["required"]?.bool ?? false,
                                     schema: schema(from: definition["schema"])))
            }
            responses.append(Response(status: entry.key,
                                      description: response["description"]?.string,
                                      headers: headers,
                                      content: content(from: response["content"])))
        }

        return APIOperation(method: method, path: path,
                         operationID: value["operationId"]?.string,
                         summary: value["summary"]?.string,
                         description: value["description"]?.string,
                         tags: (value["tags"]?.array ?? []).compactMap(\.string),
                         isDeprecated: value["deprecated"]?.bool ?? false,
                         parameters: inherited + own,
                         requestBody: requestBody,
                         responses: responses)
    }

    mutating func parameters(from value: DocValue?) -> [Parameter] {
        var parameters: [Parameter] = []
        for raw in value?.array ?? [] {
            guard let value = deref(raw), let name = value["name"]?.string,
                  let location = Parameter.Location(rawValue: value["in"]?.string ?? "") else { continue }
            // A parameter describes its value with `schema`, or rarely with one `content` entry.
            let schemaValue = value["schema"] ?? value["content"]?.object?.entries.first?.value["schema"]
            let example = value["example"] ?? value["examples"]?.object?.entries.first?.value["value"]
            parameters.append(Parameter(name: name, location: location,
                                        isRequired: location == .path || value["required"]?.bool == true,
                                        isDeprecated: value["deprecated"]?.bool ?? false,
                                        description: value["description"]?.string,
                                        schema: schema(from: schemaValue),
                                        example: example))
        }
        return parameters
    }

    mutating func content(from value: DocValue?) -> [MediaType] {
        var content: [MediaType] = []
        for entry in value?.object?.entries ?? [] {
            var examples: [Example] = []
            if let example = entry.value["example"] {
                examples.append(Example(name: nil, summary: nil, value: example))
            }
            for named in entry.value["examples"]?.object?.entries ?? [] {
                guard let example = deref(named.value), let exampleValue = example["value"] else { continue }
                examples.append(Example(name: named.key, summary: example["summary"]?.string, value: exampleValue))
            }
            content.append(MediaType(contentType: entry.key,
                                     schema: schema(from: entry.value["schema"]),
                                     examples: examples))
        }
        return content
    }

    mutating func schema(from value: DocValue?) -> Schema? {
        guard let value else { return nil }
        guard value.object != nil else {
            // `true` and `false` are schemas too: anything, or nothing.
            return value.bool != nil ? Schema() : nil
        }
        var schema = Schema()
        if let reference = value["$ref"]?.string {
            schema.reference = reference
            schema.description = value["description"]?.string
            if queued.insert(reference).inserted { pending.append(reference) }
            return schema
        }

        switch value["type"] {
        case .string(let type): schema.types = [type]
        case .array(let types): schema.types = types.compactMap(\.string)
        default: break
        }
        // OpenAPI 3.1 writes nullable as a "null" type, 3.0 as `nullable: true`.
        if schema.types.contains("null") {
            schema.isNullable = true
            schema.types.removeAll { $0 == "null" }
        }
        if value["nullable"]?.bool == true { schema.isNullable = true }

        schema.format = value["format"]?.string
        schema.title = value["title"]?.string
        schema.description = value["description"]?.string
        schema.isDeprecated = value["deprecated"]?.bool ?? false
        schema.isReadOnly = value["readOnly"]?.bool ?? false
        schema.isWriteOnly = value["writeOnly"]?.bool ?? false

        let required = Set((value["required"]?.array ?? []).compactMap(\.string))
        for entry in value["properties"]?.object?.entries ?? [] {
            guard let property = self.schema(from: entry.value) else { continue }
            schema.properties.append(.init(name: entry.key, schema: property, isRequired: required.contains(entry.key)))
        }
        schema.items = self.schema(from: value["items"])
        if let additional = value["additionalProperties"] {
            if let allowed = additional.bool {
                schema.allowsAdditionalProperties = allowed
            } else {
                schema.allowsAdditionalProperties = true
                schema.additionalProperties = self.schema(from: additional)
            }
        }

        schema.allOf = schemaList(value["allOf"])
        schema.oneOf = schemaList(value["oneOf"])
        schema.anyOf = schemaList(value["anyOf"])
        schema.discriminatorProperty = value["discriminator"]?["propertyName"]?.string

        schema.enumValues = value["enum"]?.array ?? []
        schema.constValue = value["const"]
        schema.defaultValue = value["default"]
        schema.example = value["example"] ?? value["examples"]?.array?.first

        schema.minimum = value["minimum"]?.double
        schema.maximum = value["maximum"]?.double
        schema.minLength = value["minLength"]?.int
        schema.maxLength = value["maxLength"]?.int
        schema.minItems = value["minItems"]?.int
        schema.maxItems = value["maxItems"]?.int
        schema.pattern = value["pattern"]?.string
        return schema
    }

    mutating func schemaList(_ value: DocValue?) -> [Schema] {
        var list: [Schema] = []
        for item in value?.array ?? [] {
            if let schema = schema(from: item) { list.append(schema) }
        }
        return list
    }
}
