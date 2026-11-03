import SwiftUI
import AppKit
import ProxyCore

@main
enum ProxyBoyMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--serve") {
            let port = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 9090
            ProxyBoyHeadless.run(port: port)
        } else {
            ProxyBoyApp.main()
        }
    }
}

struct ProxyBoyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    /// `ProxyBoy --record`: start the proxy immediately without touching the
    /// system proxy (handy for development and UI testing).
    private static let autoRecord = CommandLine.arguments.contains("--record")

    var body: some Scene {
        WindowGroup("ProxyBoy") {
            ContentView()
                .environment(model)
                .frame(minWidth: 1100, minHeight: 600)
                .onAppear {
                    if Self.autoRecord && !model.isRecording {
                        model.autoConfigureSystemProxy = false
                        model.startRecording()
                    }
                    DevSnapshotDriver.startIfRequested(model: model)
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Ensures the executable behaves as a regular foreground app (needed when
/// launched via `swift run` rather than from a signed bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless proxy mode (`ProxyBoy --serve [port]`) — runs the engine with no UI,
/// logging captured exchanges to stderr. Useful for scripting and verification.
enum ProxyBoyHeadless {
    static func run(port: Int) {
        let log: @Sendable (String) -> Void = { s in
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }

        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ProxyBoy", isDirectory: true)
        let ca = try? CertificateAuthority.generateOrLoad(directoryURL: dir)
        if let ca {
            log("Root CA: \(ca.rootCertificateURL.path)")
        } else {
            log("Root CA unavailable — HTTP only.")
        }

        let server = ProxyServer(port: port, host: "0.0.0.0", ca: ca) { tx in
            let outcome = tx.error ?? tx.statusCode.map(String.init) ?? "?"
            let ws = tx.isWebSocket ? " ws-msgs=\(tx.webSocketMessages.count)" : ""
            log("[\(tx.method)] \(tx.absoluteURLString) -> \(outcome)\(ws)")
        }
        do {
            try server.start()
            let bound = server.boundPort ?? port
            log("ProxyBoy listening on 0.0.0.0:\(bound)")
            if let ip = NetworkInterface.primaryIPv4() {
                log("Devices: set proxy to \(ip):\(bound), then open http://\(ip):\(bound) to install the CA")
            }
        } catch {
            log("Failed to start: \(error)")
            exit(1)
        }
        dispatchMain()
    }
}

/// Discovers the Mac's LAN IPv4 address (preferring en0 / Wi-Fi).
enum NetworkInterface {
    static func primaryIPv4() -> String? {
        var candidate: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let flags = Int32(interface.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let addr = interface.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                              &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            if name == "en0" { return ip }          // Wi-Fi / primary — best match
            if candidate == nil { candidate = ip }  // fall back to any other interface
        }
        return candidate
    }
}

/// Observable application state: proxy lifecycle + captured traffic.
@MainActor
@Observable
final class AppModel {
    var transactions: [CapturedTransaction] = []
    var selection: CapturedTransaction.ID?
    var searchText: String = ""
    var hostFilter: String? = nil          // nil = all hosts
    var methodFilter: String? = nil        // nil = all methods
    var statusFilter: StatusFilter = .all
    var contentFilter: ContentCategory? = nil
    var groupByHost: Bool = false
    /// Hosts whose group row is collapsed (grouped mode). Groups start expanded.
    var collapsedHosts: Set<String> = []

    /// Inspector tab, kept across selections.
    var inspectorTab: InspectorTab = .response
    /// Body view mode the user last picked explicitly (nil = choose automatically).
    var preferredBodyMode: BodyMode? = nil

    /// Row selection for the traffic table (host-group rows map to nil selection).
    var rowSelection: TrafficRow.ID? {
        get { selection.map(TrafficRow.transactionRowID) }
        set { selection = newValue.flatMap(TrafficRow.transactionID) }
    }

    var hasActiveFilters: Bool {
        methodFilter != nil || statusFilter != .all || contentFilter != nil || !searchText.isEmpty
    }
    func resetFilters() {
        methodFilter = nil
        statusFilter = .all
        contentFilter = nil
        searchText = ""
    }

    var isRecording: Bool = false
    var listenPort: Int = 9090
    var statusText: String = "Idle"

    /// When on, the proxy binds to 0.0.0.0 so physical devices on the LAN can connect.
    var allowLANDevices: Bool = false
    /// The Mac's LAN IPv4 address (what a device should point its proxy at).
    var lanIPAddress: String? { NetworkInterface.primaryIPv4() }

    /// HTTPS interception authority (nil if certificate setup failed).
    let certificateAuthority: CertificateAuthority?
    var httpsEnabled: Bool { certificateAuthority != nil }
    var caCertificateURL: URL? { certificateAuthority?.rootCertificateURL }

    /// Automatically point the macOS system proxy at ProxyBoy while recording.
    var autoConfigureSystemProxy: Bool = true
    private let systemProxy = SystemProxyConfigurator()

    /// Response-override rules (edited in the Rules sheet, applied live by the proxy).
    var overrideRules: [OverrideRule] = []
    let ruleStore = RuleStore()
    func syncRules() { ruleStore.setRules(overrideRules) }
    var enabledRuleCount: Int { overrideRules.filter(\.isEnabled).count }

    /// Breakpoints: pause matching requests/responses so the user can edit or abort them.
    var breakpointRequestsEnabled: Bool = false
    var breakpointResponsesEnabled: Bool = false
    var breakpointURLContains: String = ""
    var breakpointsEnabled: Bool { breakpointRequestsEnabled || breakpointResponsesEnabled }
    let breakpoints = BreakpointController()
    var pausedItems: [BreakpointPending] = []

    func syncBreakpoints() {
        breakpoints.configure(requestsEnabled: breakpointRequestsEnabled,
                              responsesEnabled: breakpointResponsesEnabled,
                              urlContains: breakpointURLContains)
    }
    func enqueuePaused(_ pending: BreakpointPending) { pausedItems.append(pending) }

    func resolveRequest(id: UUID, decision: RequestDecision) {
        guard let index = pausedItems.firstIndex(where: { $0.id == id }) else { return }
        let item = pausedItems.remove(at: index)
        if case .request(_, let resume) = item.kind { resume(decision) }
    }
    func resolveResponse(id: UUID, decision: ResponseDecision) {
        guard let index = pausedItems.firstIndex(where: { $0.id == id }) else { return }
        let item = pausedItems.remove(at: index)
        if case .response(_, let resume) = item.kind { resume(decision) }
    }

    private var server: ProxyServer?
    let stream: AsyncStream<CapturedTransaction>
    private let continuation: AsyncStream<CapturedTransaction>.Continuation

    init() {
        (stream, continuation) = AsyncStream<CapturedTransaction>.makeStream()
        self.certificateAuthority = AppModel.makeCertificateAuthority()

        // Always restore the system proxy on quit, even if the user didn't stop first.
        let systemProxy = self.systemProxy
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { _ in
            systemProxy.restore()
        }
    }

    private static func makeCertificateAuthority() -> CertificateAuthority? {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("ProxyBoy", isDirectory: true)
        return try? CertificateAuthority.generateOrLoad(directoryURL: dir)
    }

    /// Reveal the Root CA certificate in Finder so the user can install & trust it.
    func revealCertificate() {
        guard let url = caCertificateURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: proxy lifecycle

    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func startRecording() {
        let cont = continuation
        syncRules()
        syncBreakpoints()
        let bindHost = allowLANDevices ? "0.0.0.0" : "127.0.0.1"
        let server = ProxyServer(port: listenPort, host: bindHost,
                                 ca: certificateAuthority, ruleStore: ruleStore,
                                 breakpoints: breakpoints) { tx in
            cont.yield(tx)
        }
        do {
            try server.start()
            self.server = server
            isRecording = true
            if autoConfigureSystemProxy {
                _ = systemProxy.enable(host: "127.0.0.1", port: server.boundPort ?? listenPort)
            }
            let https = httpsEnabled ? "HTTP+HTTPS" : "HTTP only"
            let reach = allowLANDevices ? (lanIPAddress ?? "0.0.0.0") : "127.0.0.1"
            let sysProxy = (autoConfigureSystemProxy && systemProxy.isActive) ? " · system proxy set" : ""
            statusText = "Listening on \(reach):\(listenPort) · \(https)\(sysProxy)"
        } catch {
            statusText = "Failed to start: \(error.localizedDescription)"
            isRecording = false
        }
    }

    func stopRecording() {
        // Release any held requests/responses so no client is left hanging.
        for item in pausedItems {
            switch item.kind {
            case .request(_, let resume): resume(.abort)
            case .response(_, let resume): resume(.abort)
            }
        }
        pausedItems.removeAll()
        systemProxy.restore()
        server?.shutdown()
        server = nil
        isRecording = false
        statusText = "Stopped"
    }

    // MARK: traffic ingestion

    func ingest(_ tx: CapturedTransaction) {
        if let index = transactions.firstIndex(where: { $0.id == tx.id }) {
            transactions[index] = tx          // upsert (e.g. streaming WebSocket messages)
        } else {
            transactions.append(tx)
        }
    }

    func clear() {
        transactions.removeAll()
        selection = nil
    }

    // MARK: derived

    struct HostSummary: Identifiable {
        let host: String
        let count: Int
        let failures: Int
        let isSecure: Bool
        var id: String { host }
    }

    var hostsWithCounts: [HostSummary] {
        Dictionary(grouping: transactions, by: { $0.host })
            .map { host, txs in
                HostSummary(host: host, count: txs.count,
                            failures: txs.filter { $0.isFailure || ($0.statusClass ?? 0) >= 4 }.count,
                            isSecure: txs.contains { $0.scheme == "https" })
            }
            .sorted { $0.host < $1.host }
    }

    /// Distinct HTTP methods seen so far (for the method filter menu).
    var methodsSeen: [String] {
        Array(Set(transactions.map(\.method))).sorted()
    }

    var failureCount: Int { transactions.filter { $0.isFailure }.count }

    var filteredTransactions: [CapturedTransaction] {
        let needle = searchText.lowercased()
        return transactions.filter { tx in
            if let hostFilter, tx.host != hostFilter { return false }
            if let methodFilter, tx.method != methodFilter { return false }
            if !statusFilter.matches(tx) { return false }
            if let contentFilter, tx.contentTypeCategory != contentFilter { return false }
            if !needle.isEmpty {
                return tx.absoluteURLString.lowercased().contains(needle)
                    || tx.method.lowercased().contains(needle)
                    || (tx.statusCode.map { String($0).contains(needle) } ?? false)
            }
            return true
        }
    }

    /// Rows for the traffic table: flat, or grouped by host with disclosure rows.
    var trafficRows: [TrafficRow] {
        let filtered = filteredTransactions
        guard groupByHost else { return filtered.map(TrafficRow.init(transaction:)) }
        let groups = Dictionary(grouping: filtered, by: { $0.host })
        return groups.keys.sorted().map { host in
            TrafficRow(host: host, transactions: groups[host] ?? [])
        }
    }

    var selectedTransaction: CapturedTransaction? {
        guard let selection else { return nil }
        return transactions.first { $0.id == selection }
    }
}


// MARK: - Development snapshot driver

/// `ProxyBoy --snapshot-dir <dir>`: polls `<dir>/cmd.txt` for simple commands
/// (`select <n>`, `tab <name>`, `mode <name>`, `group on|off`, `host <name>|all`,
/// `search <text>`, `snap <file.png>`, `snapview cert|breakpoints <file.png>`) so the UI can be driven and rendered to
/// PNG without screen-recording permission. Development/testing aid only.
@MainActor
final class DevSnapshotDriver {
    private static var shared: DevSnapshotDriver?
    private let dir: URL
    private let model: AppModel
    private var timer: Timer?

    static func startIfRequested(model: AppModel) {
        guard shared == nil,
              let i = CommandLine.arguments.firstIndex(of: "--snapshot-dir"),
              i + 1 < CommandLine.arguments.count else { return }
        let driver = DevSnapshotDriver(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]), model: model)
        driver.start()
        shared = driver
    }

    private init(dir: URL, model: AppModel) {
        self.dir = dir
        self.model = model
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let file = dir.appendingPathComponent("cmd.txt")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard let cmd = parts.first else { continue }
            let arg = parts.count > 1 ? parts[1] : ""
            switch cmd {
            case "select":
                let visible = model.filteredTransactions
                if let n = Int(arg), visible.indices.contains(n) { model.selection = visible[n].id }
            case "tab": if let t = InspectorTab(rawValue: arg) { model.inspectorTab = t }
            case "mode": model.preferredBodyMode = BodyMode(rawValue: arg)
            case "group": model.groupByHost = (arg == "on")
            case "host": model.hostFilter = (arg == "all") ? nil : arg
            case "search": model.searchText = arg
            case "snapview":
                // `snapview cert|breakpoints <file.png>`: render a popover's content at its
                // ideal size (the same sizing a popover uses) without opening it.
                let args = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2 else { break }
                let view: AnyView
                switch args[0] {
                case "cert": view = AnyView(CertificateInfoView().environment(model))
                case "breakpoints": view = AnyView(BreakpointConfigView().environment(model))
                default: continue
                }
                let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(args[1]))
                }
            case "snap":
                // Give SwiftUI a couple of frames to lay out before rendering.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.snapshot(to: self!.dir.appendingPathComponent(arg))
                }
            default: break
            }
        }
    }

    private func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}
