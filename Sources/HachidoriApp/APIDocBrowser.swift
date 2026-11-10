import SwiftUI
import AppKit
import APIDocs

/// A window for reading one imported OpenAPI document: its operations by tag on the
/// left, the selected operation's documentation on the right.
struct APIDocBrowser: View {
    static let windowID = "api-docs"
    private static let overviewID = "overview"

    let documentID: UUID?
    @Environment(APIDocsModel.self) private var docs
    @State private var selection: String? = APIDocBrowser.overviewID
    @State private var search = ""

    var body: some View {
        Group {
            if let entry = docs.entry(documentID) {
                if let document = entry.document {
                    browser(entry: entry, document: document)
                } else if let error = entry.loadError {
                    ContentUnavailableView {
                        Label("Couldn't Read the Document", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Reload from File") { docs.reload(entry.id) }
                    }
                    .navigationTitle(entry.record.title)
                } else {
                    ProgressView("Reading \(entry.record.title)…")
                        .navigationTitle(entry.record.title)
                }
            } else {
                ContentUnavailableView("Document Removed", systemImage: "doc.text",
                                       description: Text("This API document is no longer in Hachidori."))
                    .navigationTitle("API Docs")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    private func browser(entry: APIDocsModel.Entry, document: APIDocument) -> some View {
        let groups = document.operationGroups(matching: search)
        return NavigationSplitView {
            List(selection: $selection) {
                Label("Overview", systemImage: "info.circle")
                    .tag(Self.overviewID)
                ForEach(groups) { group in
                    Section(group.name) {
                        ForEach(group.operations) { operation in
                            OperationRow(operation: operation)
                                .tag(Self.rowID(group: group.name, operation: operation))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .searchable(text: $search, placement: .sidebar, prompt: "Filter operations")
            .navigationSplitViewColumnWidth(min: 260, ideal: 330, max: 520)
            .overlay {
                if groups.isEmpty, !search.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let operation = selectedOperation(in: document) {
                OperationDocView(document: document, operation: operation)
                    // A fresh view per operation, so expanded rows don't carry over.
                    .id(operation.id)
            } else {
                APIDocOverview(entry: entry, document: document)
            }
        }
        .navigationTitle(document.title)
        .navigationSubtitle(Self.subtitle(document))
        #if DEBUG
        .onReceive(NotificationCenter.default.publisher(for: .devSelectOperation)) { note in
            guard let id = note.userInfo?["id"] as? String else { return }
            if let group = document.operationGroups().first(where: { $0.operations.contains { $0.id == id } }),
               let operation = group.operations.first(where: { $0.id == id }) {
                selection = Self.rowID(group: group.name, operation: operation)
            } else {
                selection = Self.overviewID
            }
        }
        #endif
    }

    // An operation with several tags has a row under each, so the row's identity includes the tag.
    private static let separator: Character = "\u{1F}"

    private static func rowID(group: String, operation: APIOperation) -> String {
        "\(group)\(separator)\(operation.id)"
    }

    private func selectedOperation(in document: APIDocument) -> APIOperation? {
        guard let selection, let cut = selection.firstIndex(of: Self.separator) else { return nil }
        let id = selection[selection.index(after: cut)...]
        return document.operations.first { $0.id == id }
    }

    static func subtitle(_ document: APIDocument) -> String {
        var parts: [String] = []
        if !document.version.isEmpty { parts.append("v\(document.version)") }
        parts.append("OpenAPI \(document.specVersion)")
        parts.append("\(document.operations.count) operations")
        return parts.joined(separator: " · ")
    }
}

private struct OperationRow: View {
    let operation: APIOperation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(operation.method)
                    .font(.caption2.monospaced().weight(.bold))
                    .foregroundStyle(Format.methodColor(operation.method))
                    .frame(width: 46, alignment: .leading)
                Text(operation.path)
                    .font(.callout.monospaced())
                    .strikethrough(operation.isDeprecated)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let summary = operation.summary {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 52)
            }
        }
        .padding(.vertical, 1)
        .help(operation.summary ?? operation.path)
    }
}

/// The document's own page: what it is, which hosts it is matched against, where it came from.
private struct APIDocOverview: View {
    let entry: APIDocsModel.Entry
    let document: APIDocument
    @Environment(APIDocsModel.self) private var docs
    @State private var hostsText = ""

    private var currentHosts: [String] { entry.matcher?.hosts ?? [] }

    private var editedHosts: [String] {
        hostsText.split(whereSeparator: { $0 == "," || $0.isWhitespace })
            .map { $0.lowercased() }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(document.title).font(.title2.weight(.semibold)).textSelection(.enabled)
                    Text(APIDocBrowser.subtitle(document) + " · \(document.schemas.count) schemas")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let description = document.description { MarkdownText(description) }
                }

                DocSection("Matching") {
                    Toggle("Match captured requests against this document", isOn: Binding(
                        get: { entry.record.isEnabled },
                        set: { docs.setEnabled(entry.id, $0) }))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hosts").font(.callout.weight(.medium))
                        HStack {
                            TextField("Any host", text: $hostsText)
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                                .autocorrectionDisabled()
                                .onSubmit(applyHosts)
                            Button("Apply", action: applyHosts)
                                .disabled(editedHosts == currentHosts)
                        }
                        Text("Requests to these hosts are matched against this document. Separate hosts with commas; `*.example.com` covers subdomains and `localhost:8080` one port. Leave it empty to match any host.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if entry.record.hosts != nil {
                            Button("Use the Document's Servers") { docs.setHosts(entry.id, nil) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }

                if !document.servers.isEmpty {
                    DocSection("Servers") {
                        ForEach(Array(document.servers.enumerated()), id: \.offset) { _, server in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(server.url).font(.callout.monospaced()).textSelection(.enabled)
                                if let description = server.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                DocSection("Source") {
                    if let path = entry.record.originalPath {
                        Text(path)
                            .font(.callout.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        HStack {
                            Button("Reload from File") { docs.reload(entry.id) }
                            Button("Show in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                            }
                        }
                    }
                    Text("Imported \(entry.record.importedAt.formatted(date: .abbreviated, time: .shortened)). Hachidori keeps its own copy, so the document stays available if the file moves.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !document.warnings.isEmpty {
                    DocSection("Skipped While Reading (\(document.warnings.count))") {
                        ForEach(document.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .font(.callout)
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Follow the stored hosts when they change elsewhere (apply, reset, reload).
        .task(id: currentHosts) { hostsText = currentHosts.joined(separator: ", ") }
    }

    private func applyHosts() {
        docs.setHosts(entry.id, editedHosts)
    }
}

#if DEBUG
extension Notification.Name {
    /// Development only: select an operation (by its `GET /path` id) in the open document browser.
    static let devSelectOperation = Notification.Name("Hachidori.devSelectOperation")
}
#endif
