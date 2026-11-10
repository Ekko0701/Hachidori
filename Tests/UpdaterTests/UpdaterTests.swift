import XCTest
@testable import Updater

final class AppVersionTests: XCTestCase {
    func testParsesTagsAndPlainVersions() {
        XCTAssertEqual(AppVersion("v0.1.2")?.parts, [0, 1, 2])
        XCTAssertEqual(AppVersion("1.10")?.parts, [1, 10])
        XCTAssertNil(AppVersion("1.0.0-beta"))
        XCTAssertNil(AppVersion(""))
        XCTAssertNil(AppVersion("1..2"))
        XCTAssertNil(AppVersion("abc"))
    }

    func testComparesNumerically() throws {
        let v = { (s: String) in AppVersion(s)! }
        XCTAssertLessThan(v("0.1.2"), v("0.1.10"))
        XCTAssertLessThan(v("0.9.9"), v("1.0"))
        XCTAssertEqual(v("1.2"), v("1.2.0"))
        XCTAssertEqual(Set([v("1.2"), v("1.2.0")]).count, 1)
        XCTAssertFalse(v("1.0.0") < v("1.0"))
    }
}

final class ReleaseTests: XCTestCase {
    private func release(tag: String = "v0.2.0", draft: Bool = false, prerelease: Bool = false,
                         assetName: String = "Hachidori-0.2.0.dmg",
                         digest: String? = "sha256:ABCDEF") throws -> GitHubRelease {
        let digestJSON = digest.map { "\"\($0)\"" } ?? "null"
        let json = """
        {"tag_name": "\(tag)", "html_url": "https://github.com/o/r/releases/tag/\(tag)",
         "body": "  Notes\\n", "draft": \(draft), "prerelease": \(prerelease),
         "assets": [{"name": "\(assetName)", "size": 42, "digest": \(digestJSON),
                     "browser_download_url": "https://github.com/o/r/releases/download/\(tag)/\(assetName)"}]}
        """
        return try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    func testOffersANewerReleaseWithItsDMG() throws {
        let update = try XCTUnwrap(release().update(newerThan: AppVersion("0.1.2")!, appName: "Hachidori"))
        XCTAssertEqual(update.version, AppVersion("0.2.0"))
        XCTAssertEqual(update.dmgURL.lastPathComponent, "Hachidori-0.2.0.dmg")
        XCTAssertEqual(update.sha256, "abcdef")
        XCTAssertEqual(update.notes, "Notes")
        XCTAssertEqual(update.dmgSize, 42)
    }

    func testIgnoresSameOrOlderDraftsPrereleasesAndMissingDMGs() throws {
        let current = AppVersion("0.2.0")!
        XCTAssertNil(try release().update(newerThan: current, appName: "Hachidori"))
        XCTAssertNil(try release(tag: "v0.1.0", assetName: "Hachidori-0.1.0.dmg").update(newerThan: current, appName: "Hachidori"))
        let older = AppVersion("0.1.0")!
        XCTAssertNil(try release(draft: true).update(newerThan: older, appName: "Hachidori"))
        XCTAssertNil(try release(prerelease: true).update(newerThan: older, appName: "Hachidori"))
        XCTAssertNil(try release(assetName: "Other-0.2.0.dmg").update(newerThan: older, appName: "Hachidori"))
    }

    func testMissingDigestMeansNoChecksum() throws {
        let update = try release(digest: nil).update(newerThan: AppVersion("0.1.0")!, appName: "Hachidori")
        XCTAssertNil(update?.sha256)
    }
}

final class UpdateInstallerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdaterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeApp(_ name: String, in folder: URL, marker: String) throws -> URL {
        let app = folder.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try marker.write(to: app.appendingPathComponent("Contents/marker"), atomically: true, encoding: .utf8)
        return app
    }

    private func marker(of app: URL) -> String? {
        try? String(contentsOf: app.appendingPathComponent("Contents/marker"), encoding: .utf8)
    }

    func testSHA256() throws {
        let file = root.appendingPathComponent("f")
        try Data("abc".utf8).write(to: file)
        XCTAssertEqual(try UpdateInstaller.sha256(of: file),
                       "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testBlockers() throws {
        XCTAssertNotNil(UpdateInstaller.blocker(for: URL(fileURLWithPath: "/usr/local/bin/hachidori")))
        XCTAssertNotNil(UpdateInstaller.blocker(for: URL(fileURLWithPath:
            "/private/var/folders/x/AppTranslocation/ABC/d/Hachidori.app")))
        XCTAssertNotNil(UpdateInstaller.blocker(for: URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        let app = try makeApp("Hachidori.app", in: root, marker: "old")
        XCTAssertNil(UpdateInstaller.blocker(for: app))
    }

    func testRejectsAppsNotSignedByTheTeam() throws {
        // Signed by Apple, not by the Hachidori team.
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(
            of: URL(fileURLWithPath: "/System/Applications/Calculator.app"),
            identifier: "com.apple.calculator", teamID: "34JS69S5XZ"))
        let unsigned = try makeApp("Hachidori.app", in: root, marker: "x")
        XCTAssertThrowsError(try UpdateInstaller.checkSignature(
            of: unsigned, identifier: "com.ekko0701.hachidori", teamID: "34JS69S5XZ"))
    }

    /// Runs the swap helper against a process that exits shortly, as the app would.
    private func runSwap(stagedExists: Bool) throws -> (target: URL, work: URL) {
        let folder = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = try makeApp("Hachidori.app", in: folder, marker: "old")
        let work = root.appendingPathComponent("work")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let staged = stagedExists
            ? try makeApp("Hachidori.app", in: work, marker: "new")
            : work.appendingPathComponent("Hachidori.app")

        let app = Process()
        app.executableURL = URL(fileURLWithPath: "/bin/sleep")
        app.arguments = ["0.5"]
        try app.run()

        let installer = UpdateInstaller(installedApp: target, bundleIdentifier: "x", signerTeamID: "x")
        try installer.launchSwap(StagedUpdate(appURL: staged, workDirectory: work, version: AppVersion("1")!),
                                 waitingFor: app.processIdentifier, relaunch: false)
        // The helper must not swap while the app is still running.
        XCTAssertEqual(marker(of: target), "old")
        app.waitUntilExit()
        let deadline = Date().addingTimeInterval(10)
        while FileManager.default.fileExists(atPath: work.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        return (target, work)
    }

    func testSwapReplacesTheAppAfterItQuits() throws {
        let (target, work) = try runSwap(stagedExists: true)
        XCTAssertEqual(marker(of: target), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }

    func testSwapKeepsTheOldAppWhenTheNewOneIsMissing() throws {
        let (target, work) = try runSwap(stagedExists: false)
        XCTAssertEqual(marker(of: target), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: work.path))
    }
}
