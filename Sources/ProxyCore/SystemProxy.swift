import Foundation

/// Configures (and restores) the macOS system HTTP/HTTPS proxy via `networksetup`.
///
/// On `enable` it records the current proxy settings of the primary network
/// service and points them at the local proxy; `restore` puts them back exactly.
/// Restoration is best-effort and must be called on stop **and** on app quit so
/// the user is never left with a dangling proxy.
public final class SystemProxyConfigurator: @unchecked Sendable {

    public struct ServiceProxyState {
        var service: String
        var httpEnabled: Bool
        var httpServer: String
        var httpPort: String
        var httpsEnabled: Bool
        var httpsServer: String
        var httpsPort: String
    }

    private let lock = NSLock()
    private var saved: ServiceProxyState?

    public init() {}

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

        _ = run("/usr/sbin/networksetup", ["-setwebproxy", service, host, String(port)])
        _ = run("/usr/sbin/networksetup", ["-setsecurewebproxy", service, host, String(port)])
        return true
    }

    /// Restore whatever was in place before `enable`. Safe to call repeatedly.
    public func restore() {
        lock.lock(); let state = saved; saved = nil; lock.unlock()
        guard let state else { return }
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
