import SwiftUI
import AppKit
import ProxyCore

/// Middle column: filter bar + the live, high-density traffic table.
struct TransactionListView: View {
    @Environment(AppModel.self) private var model
    @State private var showingCertInfo = false
    @State private var showingRules = false
    @State private var showingBreakpoints = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            FilterBar()
            Divider()
            Group {
                if model.transactions.isEmpty {
                    EmptyStateView()
                } else if model.trafficRows.isEmpty {
                    ContentUnavailableView {
                        Label("No Matching Requests", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Nothing captured matches the current filters.")
                    } actions: {
                        Button("Reset Filters") { model.resetFilters() }
                    }
                } else {
                    TrafficTable()
                }
            }
        }
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Filter by URL, method or status")
        .toolbar { toolbarContent }
        .navigationTitle("Hachidori")
        .navigationSubtitle(model.hostFilter ?? "All Requests")
        .sheet(isPresented: $showingRules) {
            RulesView().environment(model)
        }
        .onReceive(NotificationCenter.default.publisher(for: .devShowSheet)) { note in
            if note.userInfo?["name"] as? String == "rules" { showingRules = true }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                model.toggleRecording()
            } label: {
                Label(model.isRecording ? "Stop" : "Record",
                      systemImage: model.isRecording ? "stop.circle.fill" : "record.circle")
            }
            .tint(model.isRecording ? .red : .accentColor)
            .keyboardShortcut("r", modifiers: .command)
            .help(model.isRecording ? "Stop the proxy (⌘R)" : "Start the proxy (⌘R)")

            Button {
                model.clear()
            } label: {
                Label("Clear", systemImage: "trash")
            }
            .disabled(model.transactions.isEmpty)
            .keyboardShortcut("k", modifiers: .command)
            .help("Clear captured traffic (⌘K)")

            Button {
                showingRules = true
            } label: {
                Label("Rules", systemImage: "slider.horizontal.3")
            }
            .tint(model.enabledRuleCount > 0 ? .orange : nil)
            .help("Response override rules (\(model.enabledRuleCount) active)")

            Button {
                showingBreakpoints.toggle()
            } label: {
                Label("Breakpoints", systemImage: model.breakpointsEnabled ? "pause.circle.fill" : "pause.circle")
            }
            .tint(model.breakpointsEnabled ? .orange : nil)
            .help("Pause & edit matching requests/responses")
            .popover(isPresented: $showingBreakpoints, arrowEdge: .bottom) {
                BreakpointConfigView().environment(model)
            }

            Button {
                showingCertInfo.toggle()
            } label: {
                Label("Certificate", systemImage: model.httpsEnabled ? "lock.shield" : "lock.slash")
            }
            .help("Root CA for HTTPS interception")
            .popover(isPresented: $showingCertInfo, arrowEdge: .bottom) {
                CertificateInfoView()
                    .environment(model)
            }
        }
    }
}

// MARK: - Filter bar

struct FilterBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Menu {
                Picker("Method", selection: $model.methodFilter) {
                    Text("All Methods").tag(String?.none)
                    if !model.methodsSeen.isEmpty { Divider() }
                    ForEach(model.methodsSeen, id: \.self) { method in
                        Text(method).tag(String?.some(method))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.methodFilter ?? "Method")
            }
            .fixedSize()
            .help("Filter by HTTP method")

            Menu {
                Picker("Status", selection: $model.statusFilter) {
                    ForEach(StatusFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.statusFilter.shortTitle)
            }
            .fixedSize()
            .help("Filter by status class")

            Menu {
                Picker("Type", selection: $model.contentFilter) {
                    Text("All Types").tag(ContentCategory?.none)
                    Divider()
                    ForEach(ContentCategory.allCases.filter { $0 != .other }, id: \.self) { category in
                        Text(category.rawValue.uppercased()).tag(ContentCategory?.some(category))
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Text(model.contentFilter?.rawValue.uppercased() ?? "Type")
            }
            .fixedSize()
            .help("Filter by response content type")

            if model.hasActiveFilters {
                Button {
                    model.resetFilters()
                } label: {
                    Label("Reset", systemImage: "xmark.circle.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset filters")
            }

            Spacer()

            Toggle(isOn: $model.groupByHost) {
                Label("Group by Host", systemImage: "rectangle.3.group")
                    .labelStyle(.iconOnly)
            }
            .toggleStyle(.button)
            .help("Group requests by host")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }
}

// MARK: - Table

struct TrafficTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Table(of: TrafficRow.self, selection: $model.rowSelection) {
            TableColumn("Method") { row in
                if let tx = row.transaction {
                    MethodBadge(method: tx.method)
                } else {
                    Image(systemName: "globe")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 60, ideal: 66, max: 80)

            TableColumn("Status") { row in
                if let tx = row.transaction {
                    StatusBadge(code: tx.statusCode, error: tx.error)
                } else {
                    Text(row.failureCount > 0 ? "\(row.failureCount) failed" : "")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .width(min: 50, ideal: 58, max: 90)

            TableColumn("Host") { row in
                if let tx = row.transaction {
                    HStack(spacing: 4) {
                        if tx.scheme == "https" {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.green)
                        }
                        Text(tx.host)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.groupByHost ? .tertiary : .primary)
                    }
                } else {
                    Text(row.host)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Path") { row in
                if let tx = row.transaction {
                    HStack(spacing: 4) {
                        if tx.wasOverridden {
                            Image(systemName: "pencil.circle.fill")
                                .foregroundStyle(.orange)
                                .help("Modified by a rule or breakpoint")
                        }
                        if tx.isWebSocket {
                            Image(systemName: "arrow.left.arrow.right.circle.fill")
                                .foregroundStyle(.teal)
                                .help("WebSocket (\(tx.webSocketMessages.count) messages)")
                        }
                        Text(tx.displayPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(tx.isFailure ? .red : .secondary)
                    }
                } else {
                    Text("\(row.count) requests · \(Format.bytes(row.totalBytes))")
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 120, ideal: 210)

            TableColumn("Type") { row in
                if let tx = row.transaction {
                    TypeTag(category: tx.contentTypeCategory)
                }
            }
            .width(min: 44, ideal: 50, max: 60)

            TableColumn("Size") { row in
                if let tx = row.transaction {
                    Text(Format.bytes(tx.responseByteCount))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 58, ideal: 66, max: 90)
            .alignment(.trailing)

            TableColumn("Duration") { row in
                if let tx = row.transaction, let d = tx.duration {
                    Text(Format.duration(d))
                        .monospacedDigit()
                        .foregroundStyle(Format.durationColor(d))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .width(min: 58, ideal: 70, max: 90)
            .alignment(.trailing)

            TableColumn("Time") { row in
                if let tx = row.transaction {
                    Text(Format.clock(tx.startedAt))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 84, ideal: 90, max: 110)
        } rows: {
            if model.groupByHost {
                ForEach(model.trafficRows) { group in
                    DisclosureTableRow(group, isExpanded: expansionBinding(for: group.host)) {
                        ForEach(group.children ?? []) { child in
                            TableRow(child)
                        }
                    }
                }
            } else {
                ForEach(model.trafficRows) { row in
                    TableRow(row)
                }
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .controlSize(.small)
        .contextMenu(forSelectionType: TrafficRow.ID.self) { ids in
            if let tx = transaction(for: ids) {
                Button("Copy URL") { Pasteboard.copy(tx.absoluteURLString) }
                Button("Copy as cURL") { Pasteboard.copy(CurlExporter.command(for: tx)) }
                Button("Copy Response Body") {
                    Pasteboard.copy(BodyText.lossyDecode(tx.decodedResponseBody, contentType: tx.headerValue("Content-Type")))
                }
                .disabled(tx.responseBody.isEmpty)
                Divider()
                Button("Show Only \(tx.host)") { model.hostFilter = tx.host }
            } else if let host = ids.first.flatMap(hostName(for:)) {
                Button("Show Only \(host)") { model.hostFilter = host }
            }
        }
    }

    private func expansionBinding(for host: String) -> Binding<Bool> {
        Binding(
            get: { !model.collapsedHosts.contains(host) },
            set: { expanded in
                if expanded { model.collapsedHosts.remove(host) } else { model.collapsedHosts.insert(host) }
            })
    }

    private func transaction(for ids: Set<TrafficRow.ID>) -> CapturedTransaction? {
        guard ids.count == 1, let id = ids.first, let txID = TrafficRow.transactionID(id) else { return nil }
        return model.transactions.first { $0.id == txID }
    }

    private func hostName(for rowID: TrafficRow.ID) -> String? {
        rowID.hasPrefix("host:") ? String(rowID.dropFirst(5)) : nil
    }
}

enum Pasteboard {
    @MainActor
    static func copy(_ string: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
    }
}

// MARK: - Badges

struct MethodBadge: View {
    let method: String
    var body: some View {
        Text(method)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Format.methodColor(method), in: RoundedRectangle(cornerRadius: 3.5))
            .frame(minWidth: 44, alignment: .leading)
    }
}

struct StatusBadge: View {
    let code: Int?
    let error: String?
    var body: some View {
        Text(label)
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(Format.statusColor(code: code, error: error))
    }
    private var label: String {
        if error != nil && code == nil { return "ERR" }
        return code.map(String.init) ?? "—"
    }
}

struct TypeTag: View {
    let category: ContentCategory
    var body: some View {
        if !category.shortLabel.isEmpty {
            Text(category.shortLabel)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Format.categoryColor(category))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Format.categoryColor(category).opacity(0.14), in: RoundedRectangle(cornerRadius: 3))
        }
    }
}
