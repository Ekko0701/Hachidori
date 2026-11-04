import SwiftUI
import ProxyCore

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 170, ideal: 200, max: 320)
        } content: {
            TransactionListView()
                .navigationSplitViewColumnWidth(min: 460, ideal: 740)
        } detail: {
            DetailView()
                .navigationSplitViewColumnWidth(min: 380, ideal: 500)
        }
        .task {
            for await tx in model.stream {
                model.ingest(tx)
            }
        }
        .task {
            for await pending in model.breakpoints.pending {
                model.enqueuePaused(pending)
            }
        }
        .sheet(isPresented: Binding(get: { !model.pausedItems.isEmpty }, set: { _ in })) {
            if let pending = model.pausedItems.first {
                BreakpointSheet(pending: pending).environment(model)
            }
        }
    }
}

// MARK: - Sidebar

/// Sidebar rows. A dedicated type (rather than `String?`) so "All Requests"
/// is a real, selectable row: SwiftUI treats a `nil` tag as "no selection".
enum SidebarItem: Hashable {
    case all
    case host(String)
    case device(String)
    case deviceHost(device: String, host: String)
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model
    /// Device groups the user collapsed (they start expanded).
    @State private var collapsedDevices: Set<String> = []

    private var selection: Binding<SidebarItem?> {
        Binding(
            get: {
                switch (model.clientFilter, model.hostFilter) {
                case (nil, nil): return .all
                case (nil, let host?): return .host(host)
                case (let device?, nil): return .device(device)
                case (let device?, let host?): return .deviceHost(device: device, host: host)
                }
            },
            set: { item in
                switch item {
                case .host(let host)?:
                    model.clientFilter = nil; model.hostFilter = host
                case .device(let device)?:
                    model.clientFilter = device; model.hostFilter = nil
                case .deviceHost(let device, let host)?:
                    model.clientFilter = device; model.hostFilter = host
                case .all?, nil:
                    model.clientFilter = nil; model.hostFilter = nil
                }
            })
    }

    var body: some View {
        List(selection: selection) {
            Section("Traffic") {
                Label("All Requests", systemImage: "square.stack.3d.up")
                    .badge(model.transactions.count)
                    .tag(SidebarItem.all)
            }
            let devices = model.devicesWithCounts
            if !devices.isEmpty {
                Section("Devices") {
                    ForEach(devices) { device in
                        DisclosureGroup(isExpanded: expansion(for: device.address)) {
                            ForEach(device.hosts) { entry in
                                SidebarHostRow(entry: entry)
                                    .tag(SidebarItem.deviceHost(device: device.address, host: entry.host))
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: device.symbolName)
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                                    .frame(width: 14)
                                Text(device.title)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 4)
                                FailureCount(device.failures)
                            }
                            .badge(device.count)
                            .help(device.isLocal ? "Traffic from this Mac" : "\(device.kind.title) at \(device.address)")
                        }
                        .tag(SidebarItem.device(device.address))
                    }
                }
            }
            if !model.hostsWithCounts.isEmpty {
                Section("Hosts") {
                    ForEach(model.hostsWithCounts) { entry in
                        SidebarHostRow(entry: entry)
                            .tag(SidebarItem.host(entry.host))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            ProxyStatusBar()
        }
    }

    private func expansion(for device: String) -> Binding<Bool> {
        Binding(get: { !collapsedDevices.contains(device) },
                set: { expanded in
                    if expanded { collapsedDevices.remove(device) } else { collapsedDevices.insert(device) }
                })
    }
}

/// One host line: scheme icon, name, failure count and request badge.
private struct SidebarHostRow: View {
    let entry: AppModel.HostSummary

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: entry.isSecure ? "lock.fill" : "globe")
                .foregroundStyle(entry.isSecure ? Color.green : Color.secondary)
                .font(.caption)
                .frame(width: 14)
            Text(entry.host)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            FailureCount(entry.failures)
        }
        .badge(entry.count)
    }
}

private struct FailureCount: View {
    let failures: Int
    init(_ failures: Int) { self.failures = failures }

    var body: some View {
        if failures > 0 {
            Text(String(failures))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.red)
                .help("\(failures) failed or 4xx/5xx")
        }
    }
}

struct ProxyStatusBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(model.isRecording ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
            if !model.transactions.isEmpty {
                HStack(spacing: 4) {
                    Text("\(model.transactions.count) requests")
                    if model.failureCount > 0 {
                        Text("·")
                        Text("\(model.failureCount) failed").foregroundStyle(.red)
                    }
                    if model.filteredTransactions.count != model.transactions.count {
                        Text("·")
                        Text("\(model.filteredTransactions.count) shown")
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }
}

// MARK: - Certificate popover

/// Explains how to install & trust the Root CA so HTTPS can be intercepted.
struct CertificateInfoView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Label(model.httpsEnabled ? "HTTPS interception ready" : "HTTPS interception unavailable",
                  systemImage: model.httpsEnabled ? "lock.shield.fill" : "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(model.httpsEnabled ? .green : .orange)

            if model.httpsEnabled {
                Text("To decrypt HTTPS traffic, install and trust the Hachidori Root CA:")
                    .font(.callout)
                VStack(alignment: .leading, spacing: 4) {
                    Text("1. Reveal `rootCA.pem` and double-click to add it to Keychain.")
                    Text("2. In Keychain Access, set it to **Always Trust**.")
                    Text("3. Start recording and route HTTPS traffic through the proxy.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)

                Button {
                    model.revealCertificate()
                } label: {
                    Label("Reveal Root CA in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderedProminent)

                if let url = model.caCertificateURL {
                    Text(url.path)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }

                Divider().padding(.vertical, 2)

                Toggle("Auto-configure macOS system proxy", isOn: $model.autoConfigureSystemProxy)
                    .font(.callout)
                Text("Points this Mac's HTTP/HTTPS proxy at Hachidori while recording (restored on stop/quit).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider().padding(.vertical, 2)

                Toggle("Test on physical devices (LAN)", isOn: $model.allowLANDevices)
                    .font(.callout)
                if model.allowLANDevices {
                    VStack(alignment: .leading, spacing: 4) {
                        if let ip = model.lanIPAddress {
                            Text("1. On the device Wi-Fi, set HTTP proxy to **\(ip):\(String(model.listenPort))** (no authentication).")
                            Text("2. In the device browser open **http://\(ip):\(String(model.listenPort))** to download the CA, install it, then trust it.")
                            Text("Android apps additionally need a debug build that trusts user CAs (network_security_config.xml).")
                                .foregroundStyle(.tertiary)
                        } else {
                            Text("No LAN IP found — connect the Mac to Wi-Fi or Ethernet.")
                        }
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    if model.isRecording {
                        Text("Restart recording to apply the LAN change.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            } else {
                Text("The Root CA could not be created, so only plain HTTP can be captured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(width: 360)
        // Popovers size themselves from the ideal height, which for Text is a
        // single line; this makes wrapped text report its real height.
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyStateView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(model.isRecording ? "Waiting for traffic…" : "Proxy is not running")
                .font(.title3.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                Text("1. Press **Record** (⌘R) to start the proxy on port \(String(model.listenPort)).")
                Text("2. Route traffic through it, e.g.:")
                Text("curl -x http://127.0.0.1:\(String(model.listenPort)) http://example.com")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

// MARK: - Detail

struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let tx = model.selectedTransaction {
            TransactionInspector(tx: tx)
        } else {
            ContentUnavailableView("No Request Selected",
                                   systemImage: "sidebar.right",
                                   description: Text("Select a request to inspect its headers, body and timing."))
        }
    }
}
