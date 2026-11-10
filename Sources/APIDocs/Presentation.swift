import Foundation

// What the document browser and the inspector show, kept here so it can be tested without UI.

extension APIDocument {
    /// Operations under one tag.
    public struct OperationGroup: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let description: String?
        public let operations: [APIOperation]
    }

    /// The name of the group for operations without a tag.
    public static let untaggedGroupName = "Other"

    /// Operations grouped by tag: declared tags first, in their order, then tags only
    /// operations mention, then untagged ones. An operation with several tags is listed
    /// under each. `search` keeps only operations that match it.
    public func operationGroups(matching search: String = "") -> [OperationGroup] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        var order = tags.map(\.name)
        var byTag: [String: [APIOperation]] = [:]
        for operation in operations where needle.isEmpty || operation.matches(search: needle) {
            for tag in operation.tags.isEmpty ? [Self.untaggedGroupName] : operation.tags {
                if byTag[tag] == nil, !order.contains(tag) { order.append(tag) }
                byTag[tag, default: []].append(operation)
            }
        }
        // Untagged operations go last, unless the document declares a tag with that name itself.
        if let index = order.firstIndex(of: Self.untaggedGroupName),
           !tags.contains(where: { $0.name == Self.untaggedGroupName }) {
            order.append(order.remove(at: index))
        }
        return order.compactMap { name in
            guard let operations = byTag[name] else { return nil }
            return OperationGroup(name: name, description: tags.first { $0.name == name }?.description,
                                  operations: operations)
        }
    }

    /// A short name for a schema's type: `User`, `string<date-time>`, `integer[]`, `Cat | Dog`.
    public func typeSummary(of schema: Schema) -> String {
        summary(of: schema, depth: 0)
    }

    private func summary(of schema: Schema, depth: Int) -> String {
        guard depth < 8 else { return "…" }
        if schema.reference != nil {
            let target = resolved(schema)
            if target.reference != nil { return target.referenceName ?? "unknown" }
            return target.name ?? summary(of: target, depth: depth + 1)
        }

        var text: String
        if let items = schema.items {
            let item = summary(of: items, depth: depth + 1)
            text = (item.contains(" ") ? "(\(item))" : item) + "[]"
        } else if schema.allOf.count == 1, schema.properties.isEmpty {
            text = summary(of: schema.allOf[0], depth: depth + 1)
        } else if !schema.oneOf.isEmpty || !schema.anyOf.isEmpty {
            text = (schema.oneOf + schema.anyOf).map { summary(of: $0, depth: depth + 1) }.joined(separator: " | ")
        } else if !schema.types.isEmpty {
            text = schema.types.joined(separator: " | ")
            if let format = schema.format { text += "<\(format)>" }
        } else if !schema.properties.isEmpty || !schema.allOf.isEmpty || schema.additionalProperties != nil {
            text = "object"
        } else if !schema.enumValues.isEmpty {
            text = "enum"
        } else if schema.constValue != nil {
            text = "const"
        } else {
            text = "any"
        }
        if schema.isNullable { text += " | null" }
        return text
    }

    /// A schema's properties, following its reference and merging in everything `allOf` adds.
    public func properties(of schema: Schema) -> [Schema.Property] {
        var visiting: Set<String> = []
        return properties(of: schema, visiting: &visiting)
    }

    private func properties(of schema: Schema, visiting: inout Set<String>) -> [Schema.Property] {
        var current = schema
        if let reference = schema.reference {
            guard visiting.insert(reference).inserted else { return [] }
            current = resolved(schema)
            if current.reference != nil { return [] }
        }
        var result: [Schema.Property] = []
        func merge(_ properties: [Schema.Property]) {
            for property in properties {
                if let index = result.firstIndex(where: { $0.name == property.name }) {
                    result[index] = property
                } else {
                    result.append(property)
                }
            }
        }
        for part in current.allOf { merge(properties(of: part, visiting: &visiting)) }
        merge(current.properties)
        return result
    }
}

extension APIOperation {
    /// Whether the operation's method, path, summary, operation ID or a tag contains `search`.
    public func matches(search: String) -> Bool {
        let needle = search.lowercased()
        if needle.isEmpty { return true }
        return path.lowercased().contains(needle)
            || method.lowercased().contains(needle)
            || (summary?.lowercased().contains(needle) ?? false)
            || (operationID?.lowercased().contains(needle) ?? false)
            || tags.contains { $0.lowercased().contains(needle) }
    }
}

extension Schema {
    /// The limits the schema sets, as short phrases: `1 … 100`, `length ≥ 1`, `pattern ^a+$`.
    public var constraintSummaries: [String] {
        var parts: [String] = []
        func number(_ value: Double) -> String {
            value == value.rounded() && abs(value) < 1e15 ? String(Int(value)) : String(value)
        }
        switch (minimum, maximum) {
        case let (low?, high?): parts.append("\(number(low)) … \(number(high))")
        case let (low?, nil): parts.append("≥ \(number(low))")
        case let (nil, high?): parts.append("≤ \(number(high))")
        default: break
        }
        switch (minLength, maxLength) {
        case let (low?, high?): parts.append("length \(low) … \(high)")
        case let (low?, nil): parts.append("length ≥ \(low)")
        case let (nil, high?): parts.append("length ≤ \(high)")
        default: break
        }
        switch (minItems, maxItems) {
        case let (low?, high?): parts.append("\(low) … \(high) items")
        case let (low?, nil): parts.append("≥ \(low) items")
        case let (nil, high?): parts.append("≤ \(high) items")
        default: break
        }
        if let pattern { parts.append("pattern \(pattern)") }
        return parts
    }
}
