import Foundation

/// Configures (and restores) the macOS system HTTP/HTTPS proxy via `networksetup`.
///
/// On `enable` it records the current proxy settings of the primary network
/// service and points them at the local proxy; `restore` puts them back exactly.
/// Restoration is best-effort and must be called on stop **and** on app quit so
/// the user is never left with a dangling proxy. With a `backupURL`, the prior state
/// is also written to disk, so `recoverAfterCrash()` can undo a session that ended
/// without restoring (a crash or force quit).
public final class SystemProxyConfigurator: @unchecked Sendable {

    public struct ServiceProxyState: Codable, Equatable {
        var service: String
        var httpEnabled: Bool
        var httpServer: String
        var httpPort: String
        var httpsEnabled: Bool
        var httpsServer: String
        var httpsPort: String
    }

    /// What `enable` changed: the prior state, the proxy it pointed the service at,
    /// and the process that did it.
    struct Backup: Codable, Equatable {
        var previous: ServiceProxyState
        var host: String
        var port: Int
        var pid: Int32 = ProcessInfo.processInfo.processIdentifier
    }

    private let lock = NSLock()
    private var saved: ServiceProxyState?
    private let backupURL: URL?

    public init(backupURL: URL? = nil) {
        self.backupURL = backupURL
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return saved != nil
    }

    /// Point the primary service's HTTP+HTTPS proxy at `host:port`, saving prior state.
    @discardableResult
    public func enable(host: String, port: Int) -> Bool {
        guard let service = primaryService() else { return false }
        let state = readState(service: service)
        lock.lock(); saved = state; lock.unlock()
        writeBackup(Backup(previous: state, host: host, port: port))

        _ = run("/usr/sbin/networksetup", ["-setwebproxy", service, host, String(port)])
        _ = run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, String(port)])
        return true
    }

    /// Restore whatever was in place before `enable`. Safe to call repeatedly.
    public func restore() {
        lock.lock(); let state = saved; saved = nil; lock.unlock()
        guard let state else { return }
        apply(state)
        removeBackup()
    }

    /// Undo a previous session that set the system proxy and never restored it.
    /// Restores only while the service still points at that session's proxy, so a
    /// setting the user changed by hand in the meantime is left alone.
    /// Returns whether settings were restored.
    @discardableResult
    public func recoverAfterCrash() -> Bool {
        guard let backupURL, let data = try? Data(contentsOf: backupURL) else { return false }
        let backup = try? JSONDecoder().decode(Backup.self, from: data)
        // Another Hachidori process (say, a debug build beside the installed app) still owns it.
        if let backup, backup.pid != ProcessInfo.processInfo.processIdentifier, kill(backup.pid, 0) == 0 {
            return false
        }
        removeBackup()
        guard let backup else { return false }
        guard Self.isStillPointingAtProxy(readState(service: backup.previous.service), backup: backup) else { return false }
        apply(backup.previous)
        return true
    }

    static func isStillPointingAtProxy(_ current: ServiceProxyState, backup: Backup) -> Bool {
        let port = String(backup.port)
        let http = current.httpEnabled && current.httpServer == backup.host && current.httpPort == port
        let https = current.httpsEnabled && current.httpsServer == backup.host && current.httpsPort == port
        return http || https
    }

    private func writeBackup(_ backup: Backup) {
        guard let backupURL, let data = try? JSONEncoder().encode(backup) else { return }
        try? data.write(to: backupURL, options: .atomic)
    }

    private func removeBackup() {
        guard let backupURL else { return }
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func apply(_ state: ServiceProxyState) {
        let ns = "/usr/sbin/networksetup"

        if state.httpEnabled, !state.httpServer.isEmpty {
            _ = run(ns, ["-setwebproxy", state.service, state.httpServer, state.httpPort])
        } else {
            _ = run(ns, ["-setwebproxystate", state.service, "off"])
        }
        if state.httpsEnabled, !state.httpsServer.isEmpty {
            _ = run(ns, ["-setsecurewebproxy", state.service, state.httpsServer, state.httpsPort])
        } else {
            _ = run(ns, ["-setsecurewebproxystate", state.service, "off"])
        }
    }

    // MARK: - Discovery

    /// The network service (e.g. "Wi-Fi") carrying the default route.
    public func primaryService() -> String? {
        guard let route = run("/sbin/route", ["-n", "get", "default"]) else { return nil }
        guard let ifaceLine = route.split(separator: "\n").first(where: { $0.contains("interface:") }) else { return nil }
        let iface = ifaceLine.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard !iface.isEmpty, let order = run("/usr/sbin/networksetup", ["-listnetworkserviceorder"]) else { return nil }

        // Blocks look like:  "(1) Wi-Fi\n(Hardware Port: Wi-Fi, Device: en0)"
        var lastService: String?
        for line in order.split(separator: "\n", omittingEmptySubsequences: false) {
            let text = String(line)
            if let name = serviceName(from: text) {
                lastService = name
            } else if text.contains("Device: \(iface))") {
                return lastService
            }
        }
        return nil
    }

    private func serviceName(from line: String) -> String? {
        // Matches "(2) Wi-Fi" -> "Wi-Fi". Skips the "(Hardware Port: ...)" lines.
        guard line.hasPrefix("("), let close = line.firstIndex(of: ")") else { return nil }
        let after = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
        return after.isEmpty ? nil : after
    }

    private func readState(service: String) -> ServiceProxyState {
        let http = parseProxy(run("/usr/sbin/networksetup", ["-getwebproxy", service]) ?? "")
        let https = parseProxy(run("/usr/sbin/networksetup", ["-getsecurewebproxy", service]) ?? "")
        return ServiceProxyState(service: service,
                                 httpEnabled: http.enabled, httpServer: http.server, httpPort: http.port,
                                 httpsEnabled: https.enabled, httpsServer: https.server, httpsPort: https.port)
    }

    private func parseProxy(_ output: String) -> (enabled: Bool, server: String, port: String) {
        var enabled = false, server = "", port = ""
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "Enabled": enabled = (parts[1].lowercased() == "yes")
            case "Server": server = parts[1]
            case "Port": port = parts[1]
            default: break
            }
        }
        return (enabled, server, port)
    }

    // MARK: - Process helper

    @discardableResult
    private func run(_ launchPath: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
