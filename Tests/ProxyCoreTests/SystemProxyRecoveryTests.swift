import XCTest
@testable import ProxyCore

/// Crash recovery decides from saved state alone, so these tests never change the
/// Mac's real proxy settings.
final class SystemProxyRecoveryTests: XCTestCase {

    private func state(http: (Bool, String, String), https: (Bool, String, String)) -> SystemProxyConfigurator.ServiceProxyState {
        .init(service: "Wi-Fi",
              httpEnabled: http.0, httpServer: http.1, httpPort: http.2,
              httpsEnabled: https.0, httpsServer: https.1, httpsPort: https.2)
    }

    private var backup: SystemProxyConfigurator.Backup {
        .init(previous: state(http: (false, "", "0"), https: (false, "", "0")), host: "127.0.0.1", port: 9090)
    }

    func testRestoresWhileStillPointingAtTheCrashedProxy() {
        let current = state(http: (true, "127.0.0.1", "9090"), https: (true, "127.0.0.1", "9090"))
        XCTAssertTrue(SystemProxyConfigurator.isStillPointingAtProxy(current, backup: backup))
    }

    func testLeavesSettingsTheUserChangedSince() {
        let corporate = state(http: (true, "proxy.example.com", "8080"), https: (true, "proxy.example.com", "8080"))
        XCTAssertFalse(SystemProxyConfigurator.isStillPointingAtProxy(corporate, backup: backup))
        let off = state(http: (false, "127.0.0.1", "9090"), https: (false, "127.0.0.1", "9090"))
        XCTAssertFalse(SystemProxyConfigurator.isStillPointingAtProxy(off, backup: backup))
    }

    func testUnreadableBackupIsDiscarded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hachidori-proxy-backup-\(UUID().uuidString).json")
        try Data("not json".utf8).write(to: url)
        XCTAssertFalse(SystemProxyConfigurator(backupURL: url).recoverAfterCrash())
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testBackupOwnedByALiveProcessIsLeftAlone() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hachidori-proxy-backup-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        var owned = backup
        owned.pid = getppid()   // the test runner's parent: alive, and not this process
        try JSONEncoder().encode(owned).write(to: url)
        XCTAssertFalse(SystemProxyConfigurator(backupURL: url).recoverAfterCrash())
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "a live session's backup must survive")
    }

    func testNoBackupMeansNothingToRecover() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("missing-\(UUID().uuidString).json")
        XCTAssertFalse(SystemProxyConfigurator(backupURL: url).recoverAfterCrash())
        XCTAssertFalse(SystemProxyConfigurator().recoverAfterCrash())
    }
}
