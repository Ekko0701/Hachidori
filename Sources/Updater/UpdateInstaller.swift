import CryptoKit
import Foundation
import Security

/// A downloaded and verified new version, waiting beside the installed app until restart.
public struct StagedUpdate: Sendable {
    public let appURL: URL
    public let workDirectory: URL
    public let version: AppVersion
}

/// Downloads a release DMG, checks it, and swaps the new app in after this one quits.
///
/// The DMG is the same file people download by hand: signed, notarized and stapled.
/// Before anything is replaced, the copied app must carry the expected bundle ID and
/// version, be signed by `signerTeamID` (passing Gatekeeper alone would accept any
/// Developer ID), and match the release's SHA-256 when GitHub reports one.
public struct UpdateInstaller: Sendable {
    public let installedApp: URL
    public let bundleIdentifier: String
    public let signerTeamID: String

    public init(installedApp: URL, bundleIdentifier: String, signerTeamID: String) {
        self.installedApp = installedApp
        self.bundleIdentifier = bundleIdentifier
        self.signerTeamID = signerTeamID
    }

    /// Why the app at `appURL` can't replace itself, or nil when it can.
    public static func blocker(for appURL: URL) -> String? {
        guard appURL.pathExtension == "app" else {
            return "Updating in place needs the packaged app. Download the new version instead."
        }
        if appURL.path.contains("/AppTranslocation/") {
            return "macOS is running Hachidori from a temporary location. Move it to the Applications folder, open it from there, then update."
        }
        let parent = appURL.deletingLastPathComponent().path
        let fm = FileManager.default
        guard fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: appURL.path) else {
            return "Hachidori can't write to \(parent), so it can't replace itself. Download the new version instead."
        }
        return nil
    }

    /// Downloads `update`, copies the app out of its DMG and verifies it.
    public func prepare(_ update: AvailableUpdate, session: URLSession = .shared) async throws -> StagedUpdate {
        let fm = FileManager.default
        // A temporary folder on the installed app's volume, so the swap is a rename.
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask,
                              appropriateFor: installedApp, create: true)
        do {
            let dmg = work.appendingPathComponent("update.dmg")
            try await Self.download(update.dmgURL, to: dmg, session: session)
            if let expected = update.sha256, try Self.sha256(of: dmg) != expected {
                throw UpdateError.checksumMismatch
            }
            let appName = installedApp.lastPathComponent
            let staged = work.appendingPathComponent(appName)
            try Self.copyApp(named: appName, fromDiskImage: dmg, to: staged,
                             mountPoint: work.appendingPathComponent("mount"))
            try? fm.removeItem(at: dmg)
            try verify(staged, expectedVersion: update.version)
            return StagedUpdate(appURL: staged, workDirectory: work, version: update.version)
        } catch {
            try? fm.removeItem(at: work)
            throw error
        }
    }

    /// Starts the helper that waits for process `pid` to exit, moves the staged app into
    /// place (restoring the old one if that fails) and, when `relaunch` is set, opens it.
    /// The caller quits the app right after.
    public func launchSwap(_ staged: StagedUpdate,
                           waitingFor pid: Int32 = ProcessInfo.processInfo.processIdentifier,
                           relaunch: Bool = true) throws {
        let script = staged.workDirectory.appendingPathComponent("swap.sh")
        try SwapScript.source.write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, String(pid), installedApp.path, staged.appURL.path,
                             staged.workDirectory.path, relaunch ? "1" : "0"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw UpdateError.cannotInstall("Couldn't start the installer: \(error.localizedDescription)")
        }
    }

    /// Deletes a staged update that will not be installed.
    public func discard(_ staged: StagedUpdate) {
        try? FileManager.default.removeItem(at: staged.workDirectory)
    }

    // MARK: verification

    func verify(_ app: URL, expectedVersion: AppVersion) throws {
        guard let info = Bundle(url: app)?.infoDictionary else { throw UpdateError.appMissing(app.lastPathComponent) }
        let identifier = info["CFBundleIdentifier"] as? String ?? "?"
        guard identifier == bundleIdentifier else {
            throw UpdateError.untrusted("Its bundle ID is \(identifier).")
        }
        let versionText = info["CFBundleShortVersionString"] as? String ?? "?"
        guard AppVersion(versionText) == expectedVersion else {
            throw UpdateError.wrongVersion(expected: expectedVersion.description, found: versionText)
        }
        try Self.checkSignature(of: app, identifier: bundleIdentifier, teamID: signerTeamID)
        let gatekeeper = try Self.run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path])
        guard gatekeeper.status == 0 else {
            throw UpdateError.untrusted("Gatekeeper rejected it: \(gatekeeper.output)")
        }
    }

    static func checkSignature(of app: URL, identifier: String, teamID: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdateError.untrusted("It has no code signature.")
        }
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else {
            throw UpdateError.untrusted("The signing requirement is invalid.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
            throw UpdateError.untrusted(message)
        }
    }

    // MARK: steps

    static func download(_ url: URL, to destination: URL, session: URLSession) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 120
        let (temporary, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.download(status)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func copyApp(named appName: String, fromDiskImage dmg: URL, to destination: URL, mountPoint: URL) throws {
        let attach = try run("/usr/bin/hdiutil", ["attach", "-nobrowse", "-readonly", "-noautoopen",
                                                  "-mountpoint", mountPoint.path, dmg.path])
        guard attach.status == 0 else { throw UpdateError.mountFailed(attach.output) }
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"]) }
        let source = mountPoint.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: source.path) else { throw UpdateError.appMissing(appName) }
        // ditto keeps the signature, extended attributes and the stapled ticket intact.
        let copy = try run("/usr/bin/ditto", [source.path, destination.path])
        guard copy.status == 0 else { throw UpdateError.cannotInstall("Couldn't copy the new version: \(copy.output)") }
    }

    /// Runs a tool and returns its exit status with stdout and stderr combined.
    static func run(_ tool: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        // Read before waiting, or a full pipe would block the tool forever.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }
}

/// The helper `launchSwap` runs. It outlives the app, so it is a plain shell script.
enum SwapScript {
    static let source = #"""
    #!/bin/bash
    # Swaps in a staged update once the running app has quit, then reopens it.
    # Arguments: <pid> <installed .app> <staged .app> <work dir> <relaunch: 1 or 0>
    pid="$1"; target="$2"; staged="$3"; work="$4"; relaunch="$5"
    trap '' HUP

    # Wait up to a minute for the app to quit. If it is still running, change nothing.
    for _ in $(seq 1 300); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        rm -rf "$work"
        exit 1
    fi

    status=1
    backup="$work/previous.app"
    if mv "$target" "$backup"; then
        if mv "$staged" "$target"; then
            status=0
        else
            mv "$backup" "$target"
        fi
    fi
    if [ "$relaunch" = 1 ]; then
        open "$target"
    fi
    rm -rf "$work"
    exit $status
    """#
}
