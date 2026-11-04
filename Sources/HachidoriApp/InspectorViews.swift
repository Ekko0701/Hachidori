import SwiftUI
import ProxyCore

enum InspectorTab: String, CaseIterable, Identifiable {
    case overview, request, response, timing, messages
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Overview"
        case .request: return "Request"
        case .response: return "Response"
        case .timing: return "Timing"
        case .messages: return "Messages"
        }
    }
}

/// Right column: header strip + segmented tabs for one transaction.
struct TransactionInspector: View {
    @Environment(AppModel.self) private var model
    let tx: CapturedTransaction

    private var availableTabs: [InspectorTab] {
        var tabs: [InspectorTab] = [.overview, .request, .response, .timing]
        if tx.isWebSocket { tabs.append(.messages) }
        return tabs
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            InspectorHeader(tx: tx)
            Divider()
            Picker("Section", selection: $model.inspectorTab) {
                ForEach(availableTabs) { t in
                    Text(t.title).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            content
        }
        .onChange(of: tx.isWebSocket, initial: true) { _, isWS in
            if model.inspectorTab == .messages && !isWS { model.inspectorTab = .response }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.inspectorTab {
        case .overview: OverviewPane(tx: tx)
        case .request: RequestPane(tx: tx)
        case .response: ResponsePane(tx: tx)
        case .timing: TimingPane(tx: tx)
        case .messages: WebSocketPane(tx: tx)
        }
    }
}

struct InspectorHeader: View {
    let tx: CapturedTransaction

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                MethodBadge(method: tx.method)
                StatusBadge(code: tx.statusCode, error: tx.error)
                TypeTag(category: tx.contentTypeCategory)
                if tx.wasOverridden {
                    Label("Modified", systemImage: "pencil.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("Modified by a rule or breakpoint")
                }
                if tx.isWebSocket {
                    Label("WebSocket", systemImage: "arrow.left.arrow.right.circle.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.teal)
                }
                Spacer()
                HStack(spacing: 6) {
                    Text(Format.bytes(tx.responseByteCount))
                    if let d = tx.duration {
                        Text("·")
                        Text(Format.duration(d)).foregroundStyle(Format.durationColor(d))
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Text(tx.absoluteURLString)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(3)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button {
                    Pasteboard.copy(tx.absoluteURLString)
                } label: {
                    Label("Copy URL", systemImage: "doc.on.doc")
                }
                Button {
                    Pasteboard.copy(CurlExporter.command(for: tx))
                } label: {
                    Label("Copy as cURL", systemImage: "terminal")
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
        .padding(12)
    }
}

// MARK: - Overview

struct OverviewPane: View {
    let tx: CapturedTransaction

    var body: some View {
        Form {
            Section("Request") {
                LabeledContent("URL") {
                    Text(tx.absoluteURLString).textSelection(.enabled).multilineTextAlignment(.trailing)
                }
                LabeledContent("Method", value: tx.method)
                LabeledContent("Scheme", value: tx.scheme)
                LabeledContent("Host", value: tx.host)
                LabeledContent("Port", value: String(tx.port))
                LabeledContent("Client", value: ClientDevice.isLocal(tx.clientAddress) ? "This Mac (\(tx.clientAddress ?? "127.0.0.1"))" : (tx.clientAddress ?? "Unknown"))
                if let ct = tx.headerValue("Content-Type", inResponse: false) {
                    LabeledContent("Content-Type", value: ct)
                }
                LabeledContent("Body size", value: Format.bytes(tx.requestByteCount))
            }
            Section("Response") {
                LabeledContent("Status") {
                    StatusBadge(code: tx.statusCode, error: tx.error)
                }
                if let ct = tx.headerValue("Content-Type") {
                    LabeledContent("Content-Type", value: ct)
                }
                if let enc = tx.responseContentEncoding {
                    LabeledContent("Content-Encoding", value: enc)
                    LabeledContent("Body size", value: "\(Format.bytes(tx.responseByteCount)) on the wire · \(Format.bytes(tx.decodedResponseBody.count)) decoded")
                } else {
                    LabeledContent("Body size", value: Format.bytes(tx.responseByteCount))
                }
                if let error = tx.error {
                    LabeledContent("Error") {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.trailing)
                    }
                }
            }
            Section("Timing") {
                LabeledContent("Started", value: Format.fullTimestamp(tx.startedAt))
                if let d = tx.duration {
                    LabeledContent("Total", value: Format.milliseconds(d))
                }
                if let ttfb = TimingPhases.timeToFirstByte(tx) {
                    LabeledContent("Time to first byte", value: Format.milliseconds(ttfb))
                }
            }
            if tx.wasOverridden || tx.isWebSocket {
                Section("Flags") {
                    if tx.wasOverridden {
                        LabeledContent("Modified", value: "Response changed by a rule or breakpoint")
                    }
                    if tx.isWebSocket {
                        LabeledContent("WebSocket", value: "\(tx.webSocketMessages.count) messages")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Request / Response

struct RequestPane: View {
    let tx: CapturedTransaction
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HeadersSection(title: "Request Headers", headers: tx.requestHeaders)
                BodySection(title: "Request Body",
                            raw: tx.requestBody,
                            decoded: tx.decodedRequestBody,
                            category: tx.requestContentCategory,
                            encoding: tx.headerValue("Content-Encoding", inResponse: false),
                            contentType: tx.headerValue("Content-Type", inResponse: false),
                            baseURL: URL(string: tx.absoluteURLString))
            }
            .padding(12)
        }
    }
}

struct ResponsePane: View {
    let tx: CapturedTransaction
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let error = tx.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                        .textSelection(.enabled)
                }
                HeadersSection(title: "Response Headers", headers: tx.responseHeaders)
                BodySection(title: "Response Body",
                            raw: tx.responseBody,
                            decoded: tx.decodedResponseBody,
                            category: tx.contentTypeCategory,
                            encoding: tx.responseContentEncoding,
                            contentType: tx.headerValue("Content-Type"),
                            baseURL: URL(string: tx.absoluteURLString))
            }
            .padding(12)
        }
    }
}

// MARK: - Headers

struct HeadersSection: View {
    let title: String
    let headers: [HeaderPair]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Text("\(headers.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if !headers.isEmpty {
                    Button("Copy All") {
                        Pasteboard.copy(headers.map { "\($0.name): \($0.value)" }.joined(separator: "\n"))
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            if headers.isEmpty {
                Text("No headers").font(.callout).foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(headers.enumerated()), id: \.element.id) { index, h in
                        GridRow {
                            Text(h.name)
                                .font(.callout.monospaced().weight(.medium))
                                .foregroundStyle(Format.headerNameColor(h.name))
                                .gridColumnAlignment(.leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground(index))
                            Text(h.value)
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(rowBackground(index))
                        }
                        .contextMenu {
                            Button("Copy Value") { Pasteboard.copy(h.value) }
                            Button("Copy Header") { Pasteboard.copy("\(h.name): \(h.value)") }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
            }
        }
    }

    private func rowBackground(_ index: Int) -> Color {
        index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .quaternarySystemFill)
    }
}

extension Format {
    static func headerNameColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "content-type", "content-encoding", "content-length", "transfer-encoding": return .orange
        case "authorization", "cookie", "set-cookie", "proxy-authorization": return .red
        case "cache-control", "etag", "expires", "last-modified", "age": return .purple
        default: return .primary
        }
    }
}

// MARK: - WebSocket

struct WebSocketPane: View {
    let tx: CapturedTransaction

    var body: some View {
        if tx.webSocketMessages.isEmpty {
            ContentUnavailableView("No Messages",
                                   systemImage: "bubble.left.and.bubble.right",
                                   description: Text("Frames appear here as they are sent and received."))
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(tx.webSocketMessages) { message in
                        WebSocketMessageRow(message: message)
                    }
                }
                .padding(12)
            }
        }
    }
}

struct WebSocketMessageRow: View {
    let message: WebSocketMessage

    private var isSent: Bool { message.direction == .sent }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isSent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                .foregroundStyle(isSent ? Color.blue : Color.green)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(isSent ? "Sent" : "Received").font(.caption.weight(.semibold))
                    Text(message.kind == .text ? "text" : "binary")
                        .font(.caption2).foregroundStyle(.secondary)
                    Text(Format.bytes(message.payload.count))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Format.clock(message.timestamp))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
                if message.kind == .text {
                    Text(SyntaxHighlighter.highlight(BodyPresentation.prettyJSONIfPossible(message.text),
                                                     category: .json))
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text("\(message.payload.count) bytes (binary)")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        .contextMenu {
            Button("Copy Message") { Pasteboard.copy(message.text) }
        }
    }
}
