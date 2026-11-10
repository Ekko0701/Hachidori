import SwiftUI
import APIDocs

/// The documentation of one operation: what it takes and what it answers.
/// Shown in the document browser, and in the inspector for a matched request.
struct OperationDocView: View {
    let document: APIDocument
    let operation: APIOperation
    /// What a captured request sent and received. Nil in the document browser.
    var actual: RequestValues?

    /// The documented response the request's status falls under, when there is one.
    private var receivedStatus: String? {
        actual?.statusCode.flatMap { operation.response(forStatus: $0)?.status }
    }

    private static let locations: [(Parameter.Location, String)] = [
        (.path, "Path"), (.query, "Query"), (.header, "Header"), (.cookie, "Cookie"),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !operation.parameters.isEmpty {
                    DocSection("Parameters") {
                        ForEach(Self.locations, id: \.0) { location, title in
                            let parameters = operation.parameters.filter { $0.location == location }
                            if !parameters.isEmpty {
                                ParameterTable(document: document, title: title, parameters: parameters, actual: actual)
                            }
                        }
                    }
                }
                if let body = operation.requestBody {
                    DocSection(body.isRequired ? "Request Body (required)" : "Request Body") {
                        if let description = body.description { MarkdownText(description) }
                        ForEach(body.content, id: \.contentType) { media in
                            MediaTypeBlock(document: document, media: media)
                        }
                    }
                }
                if !operation.responses.isEmpty {
                    DocSection("Responses") {
                        if let status = actual?.statusCode, receivedStatus == nil {
                            Label("This request got \(status), which the document doesn't list.",
                                  systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                        }
                        ForEach(operation.responses, id: \.status) { response in
                            // With a received status, open that response; otherwise the successful ones.
                            ResponseBlock(document: document, response: response,
                                          isReceived: response.status == receivedStatus,
                                          startsExpanded: receivedStatus.map { $0 == response.status }
                                              ?? (response.status.hasPrefix("2") || operation.responses.count == 1))
                        }
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                MethodBadge(method: operation.method)
                Text(operation.path)
                    .font(.title3.monospaced())
                    .strikethrough(operation.isDeprecated)
                    .textSelection(.enabled)
                if operation.isDeprecated { DocTag("deprecated", color: .orange) }
            }
            if let summary = operation.summary {
                Text(summary).font(.headline).textSelection(.enabled)
            }
            if let description = operation.description { MarkdownText(description) }
            if let operationID = operation.operationID {
                Text("Operation ID: \(operationID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Building blocks

struct DocSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Description text; OpenAPI descriptions are Markdown, shown with inline styling.
struct MarkdownText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var attributed: AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct DocTag: View {
    let text: String
    let color: Color

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// The lines under a parameter or property: description, allowed values, default, example, limits.
private struct SchemaDetails: View {
    let document: APIDocument
    let description: String?
    let schema: Schema?
    var example: DocValue?

    var body: some View {
        let resolved = schema.map(document.resolved)
        // For an array, the allowed values are its items'.
        let values = resolved.map { $0.enumValues.isEmpty ? ($0.items.map(document.resolved)?.enumValues ?? []) : $0.enumValues } ?? []
        VStack(alignment: .leading, spacing: 2) {
            if let text = description ?? resolved?.description, !text.isEmpty {
                MarkdownText(text)
            }
            if !values.isEmpty {
                line("Allowed", values.map { $0.string ?? $0.jsonText() }.joined(separator: ", "))
            }
            if let constant = resolved?.constValue { line("Always", constant.jsonText()) }
            if let fallback = resolved?.defaultValue { line("Default", fallback.jsonText()) }
            if let example = example ?? resolved?.example { line("Example", example.jsonText()) }
            if let limits = resolved?.constraintSummaries, !limits.isEmpty {
                line("Limits", limits.joined(separator: ", "))
            }
        }
    }

    private func line(_ label: String, _ value: String) -> some View {
        (Text("\(label): ").foregroundStyle(.secondary) + Text(value).font(.caption.monospaced()))
            .font(.caption)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ParameterTable: View {
    let document: APIDocument
    let title: String
    let parameters: [Parameter]
    let actual: RequestValues?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(parameters.enumerated()), id: \.offset) { index, parameter in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(parameter.name)
                                .font(.callout.monospaced().weight(.medium))
                                .strikethrough(parameter.isDeprecated)
                                .textSelection(.enabled)
                            if parameter.isRequired { RequiredMark() }
                            Text(parameter.schema.map(document.typeSummary) ?? "any")
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                            if parameter.isDeprecated { DocTag("deprecated", color: .orange) }
                        }
                        SchemaDetails(document: document, description: parameter.description,
                                      schema: parameter.schema, example: parameter.example)
                        if let actual { SentValue(value: actual.value(for: parameter), isRequired: parameter.isRequired) }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .quaternarySystemFill))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }
}

/// What the captured request sent for a parameter.
private struct SentValue: View {
    let value: String?
    let isRequired: Bool

    var body: some View {
        if let value {
            (Text("Sent: ").foregroundStyle(.secondary)
                + Text(value.isEmpty ? "(empty)" : value).font(.caption.monospaced().weight(.semibold)).foregroundStyle(Color.accentColor))
                .font(.caption)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        } else if isRequired {
            Label("Not sent, though the document requires it", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        } else {
            Text("Not sent").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

private struct RequiredMark: View {
    var body: some View {
        Text("required")
            .font(.caption2.weight(.medium))
            .foregroundStyle(.red)
    }
}

/// One content type of a request or response body: its schema and examples.
private struct MediaTypeBlock: View {
    let document: APIDocument
    let media: MediaType

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.contentType)
                .font(.caption.monospaced().weight(.medium))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let schema = media.schema {
                SchemaTree(document: document, schema: schema)
            }
            ForEach(Array(media.examples.enumerated()), id: \.offset) { _, example in
                ExampleBlock(example: example)
            }
        }
    }
}

private struct ExampleBlock: View {
    let example: Example
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                    Text(title).font(.caption.weight(.medium))
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if isExpanded {
                let json = example.value.string ?? example.value.jsonText(pretty: true)
                Text(SyntaxHighlighter.highlight(json, category: .json))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .quaternarySystemFill), in: RoundedRectangle(cornerRadius: 6))
                    .contextMenu {
                        Button("Copy Example") { Pasteboard.copy(json) }
                    }
            }
        }
    }

    private var title: String {
        var title = "Example"
        if let name = example.name { title += ": \(name)" }
        if let summary = example.summary { title += " — \(summary)" }
        return title
    }
}

private struct ResponseBlock: View {
    let document: APIDocument
    let response: Response
    /// Whether this is the response the captured request got.
    let isReceived: Bool
    @State private var isExpanded: Bool

    init(document: APIDocument, response: Response, isReceived: Bool, startsExpanded: Bool) {
        self.document = document
        self.response = response
        self.isReceived = isReceived
        _isExpanded = State(initialValue: startsExpanded)
    }

    private var hasDetails: Bool { !response.headers.isEmpty || !response.content.isEmpty }

    /// `200`, or the first code of a range such as `4XX`; nil for `default`.
    private var representativeCode: Int? {
        if let code = Int(response.status) { return code }
        if let digit = response.status.first?.wholeNumberValue, response.status.count == 3 { return digit * 100 }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                if hasDetails { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isExpanded && hasDetails ? .degrees(90) : .zero)
                        .opacity(hasDetails ? 1 : 0)
                    Text(response.status)
                        .font(.callout.monospaced().weight(.semibold))
                        .foregroundStyle(Format.statusColor(code: representativeCode, error: nil))
                    if let description = response.description {
                        Text(description).font(.callout).multilineTextAlignment(.leading)
                    }
                    if isReceived { DocTag("received", color: .accentColor) }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded, hasDetails {
                VStack(alignment: .leading, spacing: 8) {
                    if !response.headers.isEmpty {
                        Text("Headers").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(response.headers, id: \.name) { header in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: 6) {
                                    Text(header.name).font(.callout.monospaced().weight(.medium))
                                    if header.isRequired { RequiredMark() }
                                    Text(header.schema.map(document.typeSummary) ?? "any")
                                        .font(.callout.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                SchemaDetails(document: document, description: header.description, schema: header.schema)
                            }
                        }
                    }
                    ForEach(response.content, id: \.contentType) { media in
                        MediaTypeBlock(document: document, media: media)
                    }
                }
                .padding(.leading, 18)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .quaternarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            if isReceived {
                RoundedRectangle(cornerRadius: 6).strokeBorder(Color.accentColor.opacity(0.6))
            }
        }
    }
}

// MARK: - Schema tree

/// A schema as an outline: each property on a line, expandable when it has properties of its own.
struct SchemaTree: View {
    let document: APIDocument
    let schema: Schema

    var body: some View {
        SchemaNode(document: document, name: nil, schema: schema, isRequired: false, depth: 0, ancestors: [])
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }
}

private struct SchemaNode: View {
    let document: APIDocument
    /// The property name; nil for the root.
    let name: String?
    let schema: Schema
    let isRequired: Bool
    let depth: Int
    /// References already open above this node. Meeting one again means the schema contains itself.
    let ancestors: Set<String>
    @State private var isExpanded: Bool

    private struct Child: Identifiable {
        let id: String
        let name: String
        let schema: Schema
        let isRequired: Bool
    }

    init(document: APIDocument, name: String?, schema: Schema, isRequired: Bool, depth: Int, ancestors: Set<String>) {
        self.document = document
        self.name = name
        self.schema = schema
        self.isRequired = isRequired
        self.depth = depth
        self.ancestors = ancestors
        let isRecursive = schema.reference.map(ancestors.contains) ?? false
        // Open the first two levels; deeper ones, and schemas that contain themselves, wait for a click.
        _isExpanded = State(initialValue: depth < 2 && !isRecursive)
    }

    private var isRecursive: Bool { schema.reference.map(ancestors.contains) ?? false }

    /// The schema whose properties are this node's children: the schema itself, or for
    /// an array (of arrays) the element schema. Also the references passed on the way.
    private var container: (schema: Schema, references: Set<String>) {
        var references = ancestors
        var current = schema
        for _ in 0..<8 {
            if let reference = current.reference { references.insert(reference) }
            let resolved = document.resolved(current)
            guard let items = resolved.items else { return (resolved, references) }
            current = items
        }
        return (document.resolved(current), references)
    }

    private func children(of container: Schema) -> [Child] {
        var children = document.properties(of: container).map {
            Child(id: "p:\($0.name)", name: $0.name, schema: $0.schema, isRequired: $0.isRequired)
        }
        if let additional = container.additionalProperties {
            children.append(Child(id: "additional", name: "(any key)", schema: additional, isRequired: false))
        }
        // The alternatives of oneOf / anyOf, when they have something to show.
        for (index, option) in (container.oneOf + container.anyOf).enumerated()
        where !document.properties(of: option).isEmpty {
            children.append(Child(id: "o:\(index)", name: "option \(index + 1)", schema: option, isRequired: false))
        }
        return children
    }

    var body: some View {
        let resolved = document.resolved(schema)
        let container = container
        let children = children(of: container.schema)

        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(isExpanded ? .degrees(90) : .zero)
                        .frame(width: 10)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(children.isEmpty ? 0 : 1)
                .disabled(children.isEmpty)

                if let name {
                    Text(name)
                        .font(.callout.monospaced().weight(.medium))
                        .strikethrough(resolved.isDeprecated)
                        .textSelection(.enabled)
                }
                if isRequired { RequiredMark() }
                Text(document.typeSummary(of: schema))
                    .font(.callout.monospaced())
                    .foregroundStyle(name == nil ? .primary : .secondary)
                    .textSelection(.enabled)
                if resolved.isReadOnly { DocTag("read-only") }
                if resolved.isWriteOnly { DocTag("write-only") }
                if resolved.isDeprecated { DocTag("deprecated", color: .orange) }
                if isRecursive { DocTag("recursive", color: .purple) }
            }
            SchemaDetails(document: document, description: schema.description, schema: schema)
                .padding(.leading, 16)

            if isExpanded {
                ForEach(children) { child in
                    SchemaNode(document: document, name: child.name, schema: child.schema,
                               isRequired: child.isRequired, depth: depth + 1, ancestors: container.references)
                        .padding(.leading, 16)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
