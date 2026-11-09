import XCTest
@testable import ProxyCore

final class SavedRulesTests: XCTestCase {
    private var dir: URL!
    private var file: SavedRulesFile { SavedRulesFile(url: dir.appendingPathComponent("rules.json")) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("SavedRulesTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileLoadsAsNone() {
        XCTAssertEqual(file.load(), .none)
    }

    func testRoundTripKeepsEveryField() throws {
        let rule = OverrideRule(name: "Mock login", isEnabled: false, methodFilter: "POST",
                                urlContains: "/login", respondLocally: true,
                                overrideStatus: true, statusCode: 401,
                                overrideBody: true, body: #"{"error":"nope"}"#,
                                contentType: "application/json",
                                extraHeaders: [HeaderKV(name: "X-Test", value: "1")])
        let saved = SavedRules(rules: [rule, OverrideRule()], breakpointURLContains: "/api/")
        try file.save(saved)
        XCTAssertEqual(file.load(), .loaded(saved))
    }

    func testFileIsOwnerOnly() throws {
        try file.save(SavedRules(rules: [OverrideRule()]))
        let perms = try FileManager.default.attributesOfItem(atPath: file.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    /// A rule saved before a field existed still loads, with that field's default.
    func testRuleMissingFieldsTakesDefaults() throws {
        let json = #"{"version":1,"rules":[{"name":"Old","urlContains":"/x","statusCode":503,"overrideStatus":true}]}"#
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: file.url)

        guard case .loaded(let saved) = file.load() else { return XCTFail("expected a load") }
        XCTAssertEqual(saved.breakpointURLContains, "")
        let rule = try XCTUnwrap(saved.rules.first)
        XCTAssertEqual(rule.name, "Old")
        XCTAssertEqual(rule.statusCode, 503)
        XCTAssertTrue(rule.isEnabled)
        XCTAssertEqual(rule.contentType, "application/json")
        XCTAssertEqual(rule.extraHeaders, [])
    }

    /// An unreadable file is moved aside rather than overwritten by the next save.
    func testUnreadableFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: file.url)

        XCTAssertEqual(file.load(), .unreadable(movedTo: file.corruptURL))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.url.path))
        XCTAssertEqual(try String(contentsOf: file.corruptURL, encoding: .utf8), "not json")
        XCTAssertEqual(file.load(), .none)
    }
}
