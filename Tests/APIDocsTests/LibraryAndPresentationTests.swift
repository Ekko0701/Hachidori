import XCTest
@testable import APIDocs

private let petsYAML = """
openapi: 3.0.3
info: {title: Pets, version: "1"}
tags:
  - {name: pets, description: Animals}
  - {name: admin}
paths:
  /pets:
    get:
      tags: [pets]
      summary: List pets
      operationId: listPets
      responses: {}
    post:
      tags: [pets, admin]
      summary: Add a pet
      responses: {}
  /health:
    get:
      summary: Health check
      responses: {}
  /owners:
    get:
      tags: [owners]
      responses:
        "200":
          description: OK
          content:
            application/json:
              schema: {$ref: '#/components/schemas/Holder'}
components:
  schemas:
    Animal:
      type: object
      required: [id]
      properties:
        id: {type: integer}
        name: {type: string, minLength: 1, maxLength: 40}
    Cat:
      allOf:
        - $ref: '#/components/schemas/Animal'
        - type: object
          properties:
            name: {type: string, description: Overrides Animal.name}
            indoor: {type: boolean}
    Loop:
      allOf:
        - $ref: '#/components/schemas/Loop'
        - properties:
            x: {type: string}
    Holder:
      type: object
      properties:
        cat: {$ref: '#/components/schemas/Cat'}
        cats: {type: array, items: {$ref: '#/components/schemas/Cat'}}
        when: {type: string, format: date-time, nullable: true}
        either: {oneOf: [{$ref: '#/components/schemas/Cat'}, {type: string}]}
        eithers: {type: array, items: {oneOf: [{type: integer}, {type: string}]}}
        only: {allOf: [{$ref: '#/components/schemas/Animal'}]}
        map: {additionalProperties: {type: integer}}
        ids: {type: array, minItems: 1, items: {type: integer, minimum: 1, maximum: 9.5}}
        code: {enum: [a, b]}
        anything: {}
        missing: {$ref: '#/components/schemas/Nope'}
        loop: {$ref: '#/components/schemas/Loop'}
        pattern: {type: string, pattern: '^a+$', minLength: 2}
"""

final class PresentationTests: XCTestCase {
    private func pets() throws -> APIDocument { try APIDocumentParser.parse(text: petsYAML) }

    /// The document and the `Holder` schema's properties by name.
    private func holder() throws -> (APIDocument, [String: Schema]) {
        let document = try pets()
        let holder = try XCTUnwrap(document.schemas["#/components/schemas/Holder"])
        return (document, Dictionary(uniqueKeysWithValues: holder.properties.map { ($0.name, $0.schema) }))
    }

    func testGroupsOperationsByTag() throws {
        let groups = try pets().operationGroups()
        XCTAssertEqual(groups.map(\.name), ["pets", "admin", "owners", "Other"])
        XCTAssertEqual(groups[0].description, "Animals")
        XCTAssertEqual(groups[0].operations.map(\.id), ["GET /pets", "POST /pets"])
        XCTAssertEqual(groups[1].operations.map(\.id), ["POST /pets"], "listed under each of its tags")
        XCTAssertEqual(groups[3].operations.map(\.id), ["GET /health"])
    }

    func testSearchFiltersOperationsAndDropsEmptyGroups() throws {
        let document = try pets()
        XCTAssertEqual(document.operationGroups(matching: "HEALTH").map(\.name), ["Other"])
        XCTAssertEqual(document.operationGroups(matching: "listpets").flatMap(\.operations).map(\.id), ["GET /pets"])
        XCTAssertEqual(document.operationGroups(matching: "post").flatMap(\.operations).map(\.id), ["POST /pets", "POST /pets"])
        XCTAssertEqual(document.operationGroups(matching: " admin ").map(\.name), ["pets", "admin"])
        XCTAssertTrue(document.operationGroups(matching: "nothing-like-this").isEmpty)
    }

    func testSummarizesTypes() throws {
        let (document, schema) = try holder()
        func summary(_ name: String) throws -> String { document.typeSummary(of: try XCTUnwrap(schema[name])) }
        XCTAssertEqual(try summary("cat"), "Cat")
        XCTAssertEqual(try summary("cats"), "Cat[]")
        XCTAssertEqual(try summary("when"), "string<date-time> | null")
        XCTAssertEqual(try summary("either"), "Cat | string")
        XCTAssertEqual(try summary("eithers"), "(integer | string)[]")
        XCTAssertEqual(try summary("only"), "Animal")
        XCTAssertEqual(try summary("map"), "object")
        XCTAssertEqual(try summary("ids"), "integer[]")
        XCTAssertEqual(try summary("code"), "enum")
        XCTAssertEqual(try summary("anything"), "any")
        XCTAssertEqual(try summary("missing"), "Nope")
        XCTAssertEqual(try summary("loop"), "Loop")
    }

    func testMergesAllOfProperties() throws {
        let (document, schema) = try holder()
        let cat = document.properties(of: try XCTUnwrap(schema["cat"]))
        XCTAssertEqual(cat.map(\.name), ["id", "name", "indoor"])
        XCTAssertEqual(cat.map(\.isRequired), [true, false, false])
        XCTAssertEqual(cat[1].schema.description, "Overrides Animal.name", "the later allOf part wins")
        // A schema whose allOf includes itself still ends.
        XCTAssertEqual(document.properties(of: try XCTUnwrap(schema["loop"])).map(\.name), ["x"])
        XCTAssertTrue(document.properties(of: try XCTUnwrap(schema["missing"])).isEmpty)
    }

    func testSummarizesConstraints() throws {
        let (document, schema) = try holder()
        let animal = try XCTUnwrap(document.schemas["#/components/schemas/Animal"])
        XCTAssertEqual(animal.properties[1].schema.constraintSummaries, ["length 1 … 40"])
        XCTAssertEqual(try XCTUnwrap(schema["ids"]).constraintSummaries, ["≥ 1 items"])
        XCTAssertEqual(try XCTUnwrap(schema["ids"]?.items).constraintSummaries, ["1 … 9.5"])
        XCTAssertEqual(try XCTUnwrap(schema["pattern"]).constraintSummaries, ["length ≥ 2", "pattern ^a+$"])
        XCTAssertTrue(try XCTUnwrap(schema["cat"]).constraintSummaries.isEmpty)
    }
}

final class RequestValuesTests: XCTestCase {
    private func parameter(_ name: String, _ location: Parameter.Location) -> Parameter {
        Parameter(name: name, location: location, isRequired: false, isDeprecated: false,
                  description: nil, schema: nil, example: nil)
    }

    func testReadsWhatTheRequestSent() {
        let values = RequestValues(
            pathParameters: ["id": "42"],
            path: "/users/42?page=2&q=caf%C3%A9+au+lait&tag=a&tag=b&ids[]=1&ids[]=2&flag&=x#frag",
            headers: [(name: "X-Trace-Id", value: "demo"), (name: "Accept", value: "a/b"),
                      (name: "accept", value: "c/d"), (name: "Cookie", value: "session=abc=def; theme=dark;  ; bare")],
            statusCode: 200)

        XCTAssertEqual(values.value(for: parameter("id", .path)), "42")
        XCTAssertEqual(values.value(for: parameter("page", .query)), "2")
        XCTAssertEqual(values.value(for: parameter("q", .query)), "café au lait")
        XCTAssertEqual(values.value(for: parameter("tag", .query)), "a, b")
        XCTAssertEqual(values.value(for: parameter("ids", .query)), "1, 2")
        XCTAssertEqual(values.value(for: parameter("flag", .query)), "")
        XCTAssertNil(values.value(for: parameter("frag", .query)))
        XCTAssertNil(values.value(for: parameter("missing", .query)))
        XCTAssertEqual(values.value(for: parameter("x-trace-id", .header)), "demo")
        XCTAssertEqual(values.value(for: parameter("Accept", .header)), "a/b, c/d")
        XCTAssertEqual(values.value(for: parameter("session", .cookie)), "abc=def")
        XCTAssertEqual(values.value(for: parameter("theme", .cookie)), "dark")
        XCTAssertEqual(values.value(for: parameter("bare", .cookie)), "")
        XCTAssertNil(values.value(for: parameter("other", .path)))
        XCTAssertEqual(values.statusCode, 200)
    }

    func testAPathWithoutAQueryHasNoQueryValues() {
        let values = RequestValues(pathParameters: [:], path: "/users", headers: [], statusCode: nil)
        XCTAssertTrue(values.query.isEmpty)
        XCTAssertTrue(values.cookies.isEmpty)
        XCTAssertNil(values.statusCode)
    }
}

final class DocLibraryTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DocLibraryTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testStartsEmpty() {
        XCTAssertEqual(DocLibrary(directory: directory).load(), .none)
    }

    func testSavesAndLoadsDocumentsAndTheirFiles() throws {
        let library = DocLibrary(directory: directory)
        let id = UUID()
        let name = try library.store(Data("openapi: 3.0.0".utf8), id: id, pathExtension: "YML")
        XCTAssertEqual(name, "\(id.uuidString).yml")
        let document = ImportedDocument(id: id, title: "Shop", storedFileName: name,
                                        originalPath: "/tmp/shop.yml", isEnabled: false,
                                        hosts: ["staging.internal"],
                                        importedAt: Date(timeIntervalSince1970: 1_800_000_000))
        try library.save([document])

        XCTAssertEqual(library.load(), .loaded([document]))
        XCTAssertEqual(try library.data(for: document), Data("openapi: 3.0.0".utf8))

        library.removeFile(for: document)
        XCTAssertThrowsError(try library.data(for: document))
    }

    func testUnknownExtensionsAreStoredAsYAML() throws {
        let id = UUID()
        XCTAssertEqual(try DocLibrary(directory: directory).store(Data(), id: id, pathExtension: "txt"),
                       "\(id.uuidString).yaml")
    }

    func testStoredFileNameCannotLeaveTheFolder() {
        let library = DocLibrary(directory: directory)
        let document = ImportedDocument(title: "x", storedFileName: "../../etc/passwd", originalPath: nil)
        XCTAssertEqual(library.fileURL(for: document).path, directory.appendingPathComponent("passwd").path)
    }

    func testAnUnreadableListIsSetAsideNotOverwritten() throws {
        let library = DocLibrary(directory: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: library.indexURL)

        XCTAssertEqual(library.load(), .unreadable(movedTo: library.corruptIndexURL))
        XCTAssertEqual(try Data(contentsOf: library.corruptIndexURL), Data("{not json".utf8))
        XCTAssertEqual(library.load(), .none)
    }
}
