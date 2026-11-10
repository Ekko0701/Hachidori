import Foundation

/// One imported OpenAPI file and the settings the user gave it.
public struct ImportedDocument: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    /// The document's title when it was imported, shown while the file is still loading.
    public var title: String
    /// The copy kept in the library folder (`<id>.yaml` or `<id>.json`).
    public var storedFileName: String
    /// Where the file was imported from, so it can be read again after it changes.
    public var originalPath: String?
    /// A disabled document stays in the library but isn't matched against traffic.
    public var isEnabled: Bool
    /// Hosts to match instead of the ones in the document's `servers`. Nil uses the document's.
    public var hosts: [String]?
    public var importedAt: Date

    public init(id: UUID = UUID(), title: String, storedFileName: String, originalPath: String?,
                isEnabled: Bool = true, hosts: [String]? = nil, importedAt: Date = Date()) {
        self.id = id
        self.title = title
        self.storedFileName = storedFileName
        self.originalPath = originalPath
        self.isEnabled = isEnabled
        self.hosts = hosts
        self.importedAt = importedAt
    }
}

/// The folder that keeps imported OpenAPI files and the list describing them.
///
/// Files are copied in, so a document keeps working after the original moves or is deleted.
public struct DocLibrary: Sendable {
    public enum LoadResult: Equatable, Sendable {
        /// No list yet (nothing imported).
        case none
        case loaded([ImportedDocument])
        /// The list could not be read. It was moved to `movedTo` so a later save
        /// does not overwrite it.
        case unreadable(movedTo: URL)
    }

    private struct Index: Codable {
        var version = 1
        var documents: [ImportedDocument]
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var indexURL: URL { directory.appendingPathComponent("index.json") }
    public var corruptIndexURL: URL { directory.appendingPathComponent("index.corrupt.json") }

    public func load() -> LoadResult {
        guard let data = try? Data(contentsOf: indexURL) else { return .none }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let index = try? decoder.decode(Index.self, from: data) {
            return .loaded(index.documents)
        }
        let fm = FileManager.default
        try? fm.removeItem(at: corruptIndexURL)
        try? fm.moveItem(at: indexURL, to: corruptIndexURL)
        return .unreadable(movedTo: corruptIndexURL)
    }

    public func save(_ documents: [ImportedDocument]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(Index(documents: documents))
        try createDirectory()
        try data.write(to: indexURL, options: .atomic)
    }

    /// Copies a document's bytes into the library and returns the file name to record.
    /// `pathExtension` is the original file's, kept so the copy still opens in an editor.
    public func store(_ data: Data, id: UUID, pathExtension: String) throws -> String {
        let known = ["yaml", "yml", "json"]
        let fileExtension = known.contains(pathExtension.lowercased()) ? pathExtension.lowercased() : "yaml"
        let name = "\(id.uuidString).\(fileExtension)"
        try createDirectory()
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    public func fileURL(for document: ImportedDocument) -> URL {
        // Only the last path component is used, so an edited index can't point outside the folder.
        directory.appendingPathComponent((document.storedFileName as NSString).lastPathComponent)
    }

    public func data(for document: ImportedDocument) throws -> Data {
        try Data(contentsOf: fileURL(for: document))
    }

    public func removeFile(for document: ImportedDocument) {
        try? FileManager.default.removeItem(at: fileURL(for: document))
    }

    private func createDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
