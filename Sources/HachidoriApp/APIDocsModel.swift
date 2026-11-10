import SwiftUI
import AppKit
import UniformTypeIdentifiers
import APIDocs
import ProxyCore

/// The OpenAPI documents the user imported: loads them at launch, imports new ones,
/// and finds the operation that documents a captured request.
@MainActor
@Observable
final class APIDocsModel {
    struct Entry: Identifiable {
        var record: ImportedDocument
        /// Nil while the file is being read, or when reading failed (`loadError`).
        var document: APIDocument?
        var matcher: OperationMatcher?
        var loadError: String?

        var id: UUID { record.id }
    }

    private(set) var entries: [Entry] = []
    /// Shown as an alert by the main window.
    var errorMessage: String?
    /// Set after an import; the main window opens the browser for it and clears this.
    var documentToOpen: UUID?

    @ObservationIgnored private let library: DocLibrary

    static let fileExtensions = ["yaml", "yml", "json"]

    init(directory: URL = AppPaths.supportDirectory().appendingPathComponent("apidocs", isDirectory: true)) {
        library = DocLibrary(directory: directory)
        switch library.load() {
        case .none:
            break
        case .loaded(let records):
            entries = records.map { Entry(record: $0) }
            for record in records { readStoredFile(for: record.id) }
        case .unreadable(let movedTo):
            errorMessage = "Couldn't read the list of imported API documents; kept it as \(movedTo.lastPathComponent)."
        }
    }

    func entry(_ id: UUID?) -> Entry? {
        guard let id else { return nil }
        return entries.first { $0.id == id }
    }

    // MARK: importing

    /// Asks for OpenAPI files and imports them.
    func chooseFilesToImport() {
        let panel = NSOpenPanel()
        panel.title = "Import OpenAPI"
        panel.message = "Choose OpenAPI 3.0 or 3.1 documents (YAML or JSON)."
        panel.prompt = "Import"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.fileExtensions.compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK else { return }
        importFiles(panel.urls)
    }

    /// Imports each file, replacing a document that was imported from the same path before.
    func importFiles(_ urls: [URL]) {
        Task {
            var failures: [String] = []
            for url in urls {
                do {
                    let data = try Data(contentsOf: url)
                    let document = try await Self.parse(data)
                    documentToOpen = try store(document, data: data, source: url)
                } catch {
                    failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n\n") }
        }
    }

    /// Reads the document again from the file it was imported from.
    func reload(_ id: UUID) {
        guard let entry = entry(id) else { return }
        guard let path = entry.record.originalPath, FileManager.default.fileExists(atPath: path) else {
            errorMessage = "The file \"\(entry.record.title)\" was imported from is no longer there. Import it again from its new place."
            return
        }
        importFiles([URL(fileURLWithPath: path)])
    }

    func remove(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        library.removeFile(for: entries[index].record)
        entries.remove(at: index)
        saveIndex()
    }

    func setEnabled(_ id: UUID, _ isEnabled: Bool) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].record.isEnabled = isEnabled
        saveIndex()
    }

    /// Sets the hosts the document is matched against. Nil goes back to the document's own servers;
    /// an empty list matches any host.
    func setHosts(_ id: UUID, _ hosts: [String]?) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].record.hosts = hosts
        if let document = entries[index].document {
            entries[index].matcher = OperationMatcher(document: document, hosts: hosts)
        }
        saveIndex()
    }

    // MARK: matching

    /// The enabled document and operation that describe a captured request.
    func match(_ tx: CapturedTransaction) -> (entry: Entry, match: OperationMatch)? {
        guard tx.method != "CONNECT" else { return nil }
        for entry in entries where entry.record.isEnabled {
            if let match = entry.matcher?.match(method: tx.method, host: tx.host, port: tx.port, path: tx.path) {
                return (entry, match)
            }
        }
        return nil
    }

    // MARK: storage

    private nonisolated static func parse(_ data: Data) async throws -> APIDocument {
        // Large documents take a noticeable moment to read; keep that off the main thread.
        try await Task.detached(priority: .userInitiated) { try APIDocumentParser.parse(data) }.value
    }

    private func store(_ document: APIDocument, data: Data, source: URL) throws -> UUID {
        let path = source.standardizedFileURL.path
        if let index = entries.firstIndex(where: { $0.record.originalPath == path }) {
            // Imported from this file before: keep its settings, replace its contents.
            var record = entries[index].record
            library.removeFile(for: record)
            record.storedFileName = try library.store(data, id: record.id, pathExtension: source.pathExtension)
            record.title = document.title
            entries[index] = Entry(record: record, document: document,
                                   matcher: OperationMatcher(document: document, hosts: record.hosts))
            saveIndex()
            return record.id
        }
        let id = UUID()
        let name = try library.store(data, id: id, pathExtension: source.pathExtension)
        let record = ImportedDocument(id: id, title: document.title, storedFileName: name, originalPath: path)
        entries.append(Entry(record: record, document: document, matcher: OperationMatcher(document: document)))
        saveIndex()
        return id
    }

    private func readStoredFile(for id: UUID) {
        guard let record = entry(id)?.record else { return }
        let library = library
        Task {
            var document: APIDocument?
            var failure: String?
            do {
                document = try await Self.parse(try library.data(for: record))
            } catch {
                failure = error.localizedDescription
            }
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
            entries[index].document = document
            entries[index].matcher = document.map { OperationMatcher(document: $0, hosts: entries[index].record.hosts) }
            entries[index].loadError = failure
        }
    }

    private func saveIndex() {
        do {
            try library.save(entries.map(\.record))
        } catch {
            errorMessage = "Couldn't save the list of API documents: \(error.localizedDescription)"
        }
    }
}
