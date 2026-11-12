import SwiftUI
import AppKit
import ProxyCore

@main
enum HachidoriMain {
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--serve") {
            let port = (i + 1 < args.count ? Int(args[i + 1]) : nil) ?? 9090
            HachidoriHeadless.run(port: port)
        } else {
            HachidoriApp.main()
        }
    }
}

struct HachidoriApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var updater = UpdateController()
    @State private var docs = APIDocsModel()

    #if DEBUG
    /// `Hachidori --record`: start the proxy immediately without touching the
    /// system proxy (handy for development and UI testing). Debug builds only.
    private static let autoRecord = CommandLine.arguments.contains("--record")
    /// `Hachidori --lan`: with `--record`, also accept LAN devices (bind 0.0.0.0).
    private static let autoLAN = CommandLine.arguments.contains("--lan")
    /// `Hachidori --port <n>`: with `--record`, listen on another port (so a
    /// second instance can run beside one already using 9090).
    private static let devPort: Int? = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--port"), i + 1 < args.count else { return nil }
        return Int(args[i + 1])
    }()
    #endif

    var body: some Scene {
        WindowGroup("Hachidori") {
            ContentView()
                .environment(model)
                .environment(updater)
                .environment(docs)
                .frame(minWidth: 1100, minHeight: 600)
                .onAppear {
                    updater.start()
                    #if DEBUG
                    if Self.autoRecord && !model.isRecording {
                        model.autoConfigureSystemProxy = false
                        model.allowLANDevices = Self.autoLAN
                        if let port = Self.devPort { model.listenPort = port }
                        model.startRecording()
                    }
                    DevSnapshotDriver.startIfRequested(model: model, docs: docs)
                    #endif
                }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import OpenAPI…") { docs.chooseFilesToImport() }
                    .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    Task { await updater.check(userInitiated: true) }
                }
                .disabled(!updater.canCheck)
            }
        }

        // One window per imported API document, so it can sit beside the traffic.
        WindowGroup("API Docs", id: APIDocBrowser.windowID, for: UUID.self) { $documentID in
            APIDocBrowser(documentID: documentID)
                .environment(docs)
        }
        .defaultSize(width: 1040, height: 720)
    }
}

/// Ensures the executable behaves as a regular foreground app (needed when
/// launched via `swift run` rather than from a signed bundle).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        // The packaged .app names its icon in Info.plist. A bare `swift run` executable
        // has no Info.plist, so set the Dock icon from the SwiftPM resource bundle,
        // which only exists beside a development build.
        if Bundle.main.bundleIdentifier == nil,
           let url = Bundle.module.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = icon
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Headless proxy mode (`Hachidori --serve [port]`) — runs the engine with no UI,
/// logging captured exchanges to stderr. Useful for scripting and verification.
enum HachidoriHeadless {
    static func run(port: Int) {
        let log: @Sendable (String) -> Void = { s in
            FileHandle.standardError.write(Data((s + "\n").utf8))
        }

        let ca = try? CertificateAuthority.generateOrLoad(directoryURL: AppPaths.supportDirectory())
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
            log("Hachidori listening on 0.0.0.0:\(bound)")
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

/// Where Hachidori keeps its Root CA and other state.
enum AppPaths {
    /// `~/Library/Application Support/Hachidori`.
    static func supportDirectory() -> URL {
        #if DEBUG
        // `--support-dir <path>`: keep a development run's CA, rules and proxy backup
        // apart from the installed app's.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--support-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: args[i + 1], isDirectory: true)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Hachidori", isDirectory: true)
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
    var clientFilter: String? = nil        // nil = all devices; else a client IP address
    var methodFilter: String? = nil        // nil = all methods
    var statusFilter: StatusFilter = .all
    var contentFilter: ContentCategory? = nil
    var groupByHost: Bool = false
    /// Hide failed CONNECT tunnels (devices that do not trust the CA retry them
    /// endlessly and bury real traffic). Remembered across launches.
    var hideConnectErrors: Bool = UserDefaults.standard.bool(forKey: "hideConnectErrors") {
        didSet {
            UserDefaults.standard.set(hideConnectErrors, forKey: "hideConnectErrors")
            pruneSidebarSelection()
        }
    }

    /// Clears a host / device filter whose rows just disappeared (e.g. a host that
    /// only ever failed CONNECT, once those are hidden) so the sidebar never points
    /// at nothing and the list does not show an empty "no matches" state.
    private func pruneSidebarSelection() {
        let visible = visibleTransactions
        if let client = clientFilter,
           !visible.contains(where: { ($0.clientAddress ?? "127.0.0.1") == client }) {
            clientFilter = nil
        }
        if let host = hostFilter,
           !visible.contains(where: { $0.host == host && (clientFilter == nil || ($0.clientAddress ?? "127.0.0.1") == clientFilter) }) {
            hostFilter = nil
        }
    }
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

    /// Automatically point the macOS system proxy at Hachidori while recording.
    var autoConfigureSystemProxy: Bool = true
    private let systemProxy = SystemProxyConfigurator(
        backupURL: AppPaths.supportDirectory().appendingPathComponent("system-proxy-backup.json"))
    /// Keeps the termination signal sources alive.
    private var signalSources: [DispatchSourceSignal] = []

    /// Response-override rules (edited in the Rules sheet, applied live by the proxy).
    /// Saved to `rules.json` and restored at launch.
    var overrideRules: [OverrideRule] = [] {
        didSet { syncRules(); scheduleSave() }
    }
    let ruleStore = RuleStore()
    func syncRules() { ruleStore.setRules(overrideRules) }
    var enabledRuleCount: Int { overrideRules.filter(\.isEnabled).count }

    /// Breakpoints: pause matching requests/responses so the user can edit or abort them.
    /// The switches start off at every launch; only the URL filter is saved.
    var breakpointRequestsEnabled: Bool = false {
        didSet { syncBreakpoints() }
    }
    var breakpointResponsesEnabled: Bool = false {
        didSet { syncBreakpoints() }
    }
    var breakpointURLContains: String = "" {
        didSet { syncBreakpoints(); scheduleSave() }
    }
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

    private let rulesFile = SavedRulesFile(url: AppPaths.supportDirectory().appendingPathComponent("rules.json"))
    @ObservationIgnored private var pendingSave: Task<Void, Never>?

    /// Coalesces saves while the user types in the rule editor.
    private func scheduleSave() {
        pendingSave?.cancel()
        pendingSave = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveRulesNow()
        }
    }

    private func flushPendingSave() {
        if pendingSave != nil { saveRulesNow() }
    }

    private func saveRulesNow() {
        pendingSave?.cancel()
        pendingSave = nil
        do {
            try rulesFile.save(SavedRules(rules: overrideRules, breakpointURLContains: breakpointURLContains))
        } catch {
            statusText = "Couldn't save rules: \(error.localizedDescription)"
        }
    }

    private var server: ProxyServer?
    let stream: AsyncStream<CapturedTransaction>
    private let continuation: AsyncStream<CapturedTransaction>.Continuation

    init() {
        (stream, continuation) = AsyncStream<CapturedTransaction>.makeStream()
        self.certificateAuthority = AppModel.makeCertificateAuthority()

        // A previous session that crashed or was force-quit may have left the system proxy
        // pointing at a port nobody listens on, which cuts the Mac off the internet.
        if systemProxy.recoverAfterCrash() {
            statusText = "Restored the system proxy left set by the previous session"
        }

        switch rulesFile.load() {
        case .none:
            break
        case .loaded(let saved):
            overrideRules = saved.rules
            breakpointURLContains = saved.breakpointURLContains
        case .unreadable(let movedTo):
            statusText = "Couldn't read saved rules; kept them as \(movedTo.lastPathComponent)"
        }
        // Loading is not an edit: hand the state to the engine without writing it back.
        syncRules()
        syncBreakpoints()
        pendingSave?.cancel()
        pendingSave = nil

        // Always restore the system proxy on quit, even if the user didn't stop first,
        // and write any rule edit still waiting for its debounced save.
        let systemProxy = self.systemProxy
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            systemProxy.restore()
            MainActor.assumeIsolated { self?.flushPendingSave() }
        }
        // `kill` and Ctrl-C end the process without a normal quit; route them through one.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    private static func makeCertificateAuthority() -> CertificateAuthority? {
        try? CertificateAuthority.generateOrLoad(directoryURL: AppPaths.supportDirectory())
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
        /// Unique within the sidebar: the same host appears under every device
        /// that talked to it *and* in the Hosts section, and `List` draws rows
        /// with colliding identities on top of each other.
        let id: String
        let host: String
        let count: Int
        let failures: Int
        let isSecure: Bool
    }

    /// Everything captured, minus the rows the user chose to hide. The sidebar,
    /// counts and the table all derive from this, so a hidden row is hidden everywhere.
    var visibleTransactions: [CapturedTransaction] {
        hideConnectErrors ? transactions.filter { !$0.isConnectError } : transactions
    }
    /// How many CONNECT errors the hide toggle is currently suppressing.
    var hiddenConnectErrorCount: Int {
        hideConnectErrors ? transactions.filter(\.isConnectError).count : 0
    }

    var hostsWithCounts: [HostSummary] { AppModel.hostSummaries(of: visibleTransactions) }

    /// Hosts in `txs` with their counts; `scope` namespaces the row identities
    /// (the device address when listing one device's hosts).
    private static func hostSummaries(of txs: [CapturedTransaction], scope: String? = nil) -> [HostSummary] {
        Dictionary(grouping: txs, by: { $0.host })
            .map { host, txs in
                HostSummary(id: scope.map { "\($0)/\(host)" } ?? host,
                            host: host, count: txs.count,
                            failures: txs.filter { $0.isFailure || ($0.statusClass ?? 0) >= 4 }.count,
                            isSecure: txs.contains { $0.scheme == "https" })
            }
            .sorted { $0.host < $1.host }
    }

    /// One client (this Mac or a LAN device) and the hosts it talked to.
    struct DeviceSummary: Identifiable {
        let address: String
        let isLocal: Bool
        let kind: ClientDevice.Kind
        let count: Int
        let failures: Int
        let hosts: [HostSummary]
        var id: String { address }
        var title: String { isLocal ? "This Mac" : address }
        var symbolName: String { isLocal ? "laptopcomputer" : kind.symbolName }
    }

    /// Captured traffic grouped by the client that sent it; this Mac first, then by address.
    var devicesWithCounts: [DeviceSummary] {
        Dictionary(grouping: visibleTransactions, by: { $0.clientAddress ?? "127.0.0.1" })
            .map { address, txs in
                let agents = txs.compactMap { $0.headerValue("User-Agent", inResponse: false) }
                return DeviceSummary(address: address,
                                     isLocal: ClientDevice.isLocal(address),
                                     kind: ClientDevice.kind(forUserAgents: agents),
                                     count: txs.count,
                                     failures: txs.filter { $0.isFailure || ($0.statusClass ?? 0) >= 4 }.count,
                                     hosts: AppModel.hostSummaries(of: txs, scope: address))
            }
            .sorted { a, b in
                if a.isLocal != b.isLocal { return a.isLocal }
                return a.address < b.address
            }
    }

    /// Whether more than one client has sent traffic (when the Client column is worth showing).
    var hasMultipleDevices: Bool {
        Set(visibleTransactions.map { $0.clientAddress ?? "127.0.0.1" }).count > 1
    }

    /// Distinct HTTP methods seen so far (for the method filter menu).
    var methodsSeen: [String] {
        Array(Set(visibleTransactions.map(\.method))).sorted()
    }

    var failureCount: Int { visibleTransactions.filter { $0.isFailure }.count }

    var filteredTransactions: [CapturedTransaction] {
        let needle = searchText.lowercased()
        return visibleTransactions.filter { tx in
            if let clientFilter, (tx.clientAddress ?? "127.0.0.1") != clientFilter { return false }
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

#if DEBUG

/// `Hachidori --snapshot-dir <dir>`: polls `<dir>/cmd.txt` for simple commands
/// (`select <n>`, `tab <name>`, `mode <name>`, `group on|off`, `host <name>|all`, `client <ip>|all`,
/// `search <text>`, `snap <file.png>`, `snapview cert|breakpoints <file.png>`) so the UI can be driven and rendered to
/// PNG without screen-recording permission. Development/testing aid only.
@MainActor
final class DevSnapshotDriver {
    private static var shared: DevSnapshotDriver?
    private let dir: URL
    private let model: AppModel
    private let docs: APIDocsModel
    private var timer: Timer?

    static func startIfRequested(model: AppModel, docs: APIDocsModel) {
        guard shared == nil,
              let i = CommandLine.arguments.firstIndex(of: "--snapshot-dir"),
              i + 1 < CommandLine.arguments.count else { return }
        let driver = DevSnapshotDriver(dir: URL(fileURLWithPath: CommandLine.arguments[i + 1]), model: model, docs: docs)
        driver.start()
        shared = driver
    }

    private init(dir: URL, model: AppModel, docs: APIDocsModel) {
        self.dir = dir
        self.model = model
        self.docs = docs
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
            case "hideconnect": model.hideConnectErrors = (arg == "on")
            case "host": model.hostFilter = (arg == "all") ? nil : arg
            case "client": model.clientFilter = (arg == "all") ? nil : arg
            case "search": model.searchText = arg
            case "statustext": model.statusText = arg
            case "bp":
                // `bp requests|responses|off [url-contains]`
                let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
                model.breakpointRequestsEnabled = parts.first == "requests"
                model.breakpointResponsesEnabled = parts.first == "responses"
                model.breakpointURLContains = parts.count > 1 ? parts[1] : ""
            case "snapview":
                // `snapview cert|breakpoints <file.png>`: render a popover's content at its
                // ideal size (the same sizing a popover uses) without opening it.
                let args = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2 else { break }
                let view: AnyView
                switch args[0] {
                case "cert": view = AnyView(CertificateInfoView().environment(model))
                case "breakpoints": view = AnyView(BreakpointConfigView().environment(model))
                // The sidebar's status bar at the sidebar's narrowest width, and at a typical one.
                case "status": view = AnyView(ProxyStatusBar().environment(model).frame(width: 170))
                case "statuswide": view = AnyView(ProxyStatusBar().environment(model).frame(width: 250))
                default: continue
                }
                let renderer = ImageRenderer(content: view.background(Color(nsColor: .windowBackgroundColor)))
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(args[1]))
                }
            case "sheet":
                // `sheet rules`: open a sheet via notification so `snap` can capture it.
                NotificationCenter.default.post(name: .devShowSheet, object: nil, userInfo: ["name": arg])
            case "addrule":
                model.overrideRules.append(OverrideRule(name: "Demo 500", urlContains: "/api/dashboard/notice",
                                                        overrideStatus: true, statusCode: 500))
            case "snapicon":
                // `snapicon <file.png>`: the Dock icon as currently set.
                if let tiff = NSApp.applicationIconImage?.tiffRepresentation,
                   let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                    try? png.write(to: dir.appendingPathComponent(arg))
                }
            case "importdoc":
                // `importdoc <path>`: import an OpenAPI file, which also opens its browser window.
                docs.importFiles([URL(fileURLWithPath: arg)])
            case "docselect":
                // `docselect GET /users/{id}`: select an operation in the open document browser.
                NotificationCenter.default.post(name: .devSelectOperation, object: nil, userInfo: ["id": arg])
            case "shot":
                // `shot <file.png> <title>`: capture the window whose title contains <title> as it
                // is on screen, title bar, toolbar and sidebar included (`snap` can't draw those).
                // `shot <file.png> sheet` captures the open sheet.
                let args = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2 else { break }
                // Bring the window forward first, so it is drawn as the active window.
                NSApp.activate(ignoringOtherApps: true)
                captureTarget(titleContaining: args[1])?.makeKeyAndOrderFront(nil)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { [weak self] in
                    self?.capture(to: self!.dir.appendingPathComponent(args[0]), titleContaining: args[1])
                }
            case "divider":
                // `divider <index> <x>`: move a divider of the main window's split view (0 = after
                // the sidebar, 1 = before the inspector) to x points from the window's left edge.
                let values = arg.split(separator: " ").compactMap { Double($0) }
                guard values.count == 2, let root = captureTarget(titleContaining: "Hachidori")?.contentView else { break }
                func splitView(in view: NSView) -> NSSplitView? {
                    if let split = view as? NSSplitView, split.arrangedSubviews.count >= 3 { return split }
                    for child in view.subviews {
                        if let found = splitView(in: child) { return found }
                    }
                    return nil
                }
                splitView(in: root)?.setPosition(values[1], ofDividerAt: Int(values[0]))
            case "winsize":
                // `winsize <width> <height>`: resize the main window.
                let size = arg.split(separator: " ").compactMap { Double($0) }
                guard size.count == 2, let window = captureTarget(titleContaining: "Hachidori") else { break }
                var frame = window.frame
                frame.origin.y += frame.height - size[1]
                frame.size = NSSize(width: size[0], height: size[1])
                window.setFrame(frame, display: true)
            case "snapwin":
                // `snapwin <file.png> <title>`: snapshot the window whose title contains <title>.
                let args = arg.split(separator: " ", maxSplits: 1).map(String.init)
                guard args.count == 2 else { break }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                    self?.snapshot(to: self!.dir.appendingPathComponent(args[0]), titleContaining: args[1])
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

    /// Captures one of this app's own windows from the window server, which needs no
    /// screen-recording permission. The function is looked up by name because the SDK
    /// no longer declares it.
    /// The window a `shot` names: the open sheet for "sheet", else the one whose title contains the text.
    private func captureTarget(titleContaining title: String) -> NSWindow? {
        title == "sheet"
            ? NSApp.windows.first { $0.isSheet && $0.isVisible }
            : NSApp.windows.first { $0.isVisible && !$0.isSheet && $0.title.contains(title) }
    }

    private func capture(to url: URL, titleContaining title: String) {
        let window = captureTarget(titleContaining: title)
        typealias CreateImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let window,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return }
        let createImage = unsafeBitCast(symbol, to: CreateImage.self)
        let onlyThisWindow: UInt32 = 1 << 3                 // kCGWindowListOptionIncludingWindow
        let withoutShadowAtFullResolution: UInt32 = 1 | 8   // BoundsIgnoreFraming | BestResolution
        guard let image = createImage(.null, onlyThisWindow, UInt32(window.windowNumber),
                                      withoutShadowAtFullResolution)?.takeRetainedValue(),
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }

    private func snapshot(to url: URL, titleContaining title: String? = nil) {
        // A named window, else an open sheet (it is its own window), else the main window.
        let named = title.flatMap { title in
            NSApp.windows.first { $0.isVisible && $0.contentView != nil && $0.title.contains(title) }
        }
        if title != nil, named == nil { return }
        let window = named
            ?? NSApp.windows.first(where: { $0.isSheet && $0.isVisible })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.title == "Hachidori" })
            ?? NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil })
        guard let window,
              let view = window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

extension Notification.Name {
    /// Development only: ask the traffic view to present a named sheet.
    static let devShowSheet = Notification.Name("Hachidori.devShowSheet")
}
#endif
