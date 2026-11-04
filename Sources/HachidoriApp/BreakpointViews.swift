import SwiftUI
import ProxyCore

/// Popover to enable request/response breakpoints and set which URLs to pause.
struct BreakpointConfigView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Label("Breakpoints", systemImage: "pause.circle").font(.headline)
            Toggle("Pause requests (before server)", isOn: $model.breakpointRequestsEnabled)
            Toggle("Pause responses (before client)", isOn: $model.breakpointResponsesEnabled)
            TextField("URL contains", text: $model.breakpointURLContains,
                      prompt: Text("empty = all requests"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text("A matching request/response pauses; edit it and press Send, or Abort to drop the connection.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 360)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: model.breakpointRequestsEnabled) { model.syncBreakpoints() }
        .onChange(of: model.breakpointResponsesEnabled) { model.syncBreakpoints() }
        .onChange(of: model.breakpointURLContains) { model.syncBreakpoints() }
    }
}

/// Routes a paused item to the request or response editor.
struct BreakpointSheet: View {
    @Environment(AppModel.self) private var model
    let pending: BreakpointPending

    var body: some View {
        switch pending.kind {
        case .request(let request, _):
            BreakpointRequestEditor(id: pending.id, request: request).environment(model)
        case .response(let response, _):
            BreakpointResponseEditor(id: pending.id, response: response).environment(model)
        }
    }
}

// MARK: - Shared pieces

private struct BreakpointTitle: View {
    @Environment(AppModel.self) private var model
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 4) {
            HStack {
                Label(title, systemImage: "pause.circle.fill").font(.headline).foregroundStyle(.orange)
                Spacer()
                if model.pausedItems.count > 1 {
                    Text("+\(model.pausedItems.count - 1) more").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(subtitle)
                .font(.caption.monospaced()).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(2).truncationMode(.middle)
        }
        .padding(12)
    }
}

private struct HeaderRowsEditor: View {
    @Binding var headers: [HeaderKV]
    var body: some View {
        ForEach($headers) { $header in
            HStack {
                TextField("Name", text: $header.name)
                TextField("Value", text: $header.value)
                Button(role: .destructive) {
                    headers.removeAll { $0.id == header.id }
                } label: { Image(systemName: "minus.circle") }
                .buttonStyle(.borderless)
            }
        }
        Button { headers.append(HeaderKV()) } label: { Label("Add header", systemImage: "plus") }
    }
}

// MARK: - Request editor

struct BreakpointRequestEditor: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let request: PausedRequest

    @State private var method = "GET"
    @State private var headers: [HeaderKV] = []
    @State private var bodyText = ""
    @State private var bodyIsText = true

    var body: some View {
        VStack(spacing: 0) {
            BreakpointTitle(title: "Paused Request", subtitle: "\(request.method)  \(request.url)")
                .environment(model)
            Divider()
            Form {
                Section("Method") { TextField("Method", text: $method) }
                Section("Headers") { HeaderRowsEditor(headers: $headers) }
                Section("Body") {
                    BodyEditor(text: $bodyText, isText: bodyIsText, byteCount: request.body.count, minHeight: 140)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(role: .destructive) {
                    model.resolveRequest(id: id, decision: .abort)
                } label: { Label("Abort", systemImage: "xmark.octagon") }
                Spacer()
                Button("Send Original") { model.resolveRequest(id: id, decision: .proceed(nil)) }
                Button("Send Edited") { model.resolveRequest(id: id, decision: .proceed(edited())) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 580)
        .onAppear(perform: load)
        .onChange(of: id) { load() }
    }

    private func load() {
        method = request.method
        headers = request.headers.map { HeaderKV(name: $0.name, value: $0.value) }
        let text = BodyText.decode(request.body, contentType: request.headers.contentType)
        bodyIsText = text != nil
        bodyText = text ?? ""
    }
    private func edited() -> EditedRequest {
        var pairs = headers.map { HeaderPair(name: $0.name, value: $0.value) }
        let body = bodyIsText ? pairs.encodeBody(bodyText, originalBody: request.body) : request.body
        return EditedRequest(method: method, headers: pairs, body: body)
    }
}

// MARK: - Response editor

struct BreakpointResponseEditor: View {
    @Environment(AppModel.self) private var model
    let id: UUID
    let response: PausedResponse

    @State private var statusCode = 200
    @State private var headers: [HeaderKV] = []
    @State private var bodyText = ""
    @State private var bodyIsText = true

    var body: some View {
        VStack(spacing: 0) {
            BreakpointTitle(title: "Paused Response", subtitle: "\(response.method)  \(response.url)")
                .environment(model)
            Divider()
            Form {
                Section("Status") { TextField("Status code", value: $statusCode, format: .number) }
                Section("Headers") { HeaderRowsEditor(headers: $headers) }
                Section("Body") {
                    BodyEditor(text: $bodyText, isText: bodyIsText, byteCount: response.body.count, minHeight: 160)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button(role: .destructive) {
                    model.resolveResponse(id: id, decision: .abort)
                } label: { Label("Abort", systemImage: "xmark.octagon") }
                Spacer()
                Button("Send Original") { model.resolveResponse(id: id, decision: .send(nil)) }
                Button("Send Edited") { model.resolveResponse(id: id, decision: .send(edited())) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 560, height: 600)
        .onAppear(perform: load)
        .onChange(of: id) { load() }
    }

    private func load() {
        statusCode = response.statusCode
        headers = response.headers.map { HeaderKV(name: $0.name, value: $0.value) }
        let text = BodyText.decode(response.body, contentType: response.headers.contentType)
        bodyIsText = text != nil
        bodyText = text ?? ""
    }
    private func edited() -> EditedResponse {
        var pairs = headers.map { HeaderPair(name: $0.name, value: $0.value) }
        let body = bodyIsText ? pairs.encodeBody(bodyText, originalBody: response.body) : response.body
        return EditedResponse(statusCode: statusCode, headers: pairs, body: body)
    }
}

// MARK: - Body editing helpers

/// Text editor for a paused body; binary bodies are left untouched and sent as-is.
private struct BodyEditor: View {
    @Binding var text: String
    let isText: Bool
    let byteCount: Int
    let minHeight: CGFloat

    var body: some View {
        if isText {
            TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: minHeight)
        } else {
            Label("Binary body (\(Format.bytes(byteCount))) — sent unchanged.", systemImage: "doc.zipper")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}

private extension Array where Element == HeaderPair {
    var contentType: String? {
        first { $0.name.lowercased() == "content-type" }?.value
    }

    /// Encodes `text` in the declared charset (from `Content-Type` or the original body's
    /// `<meta charset>`). When the text no longer fits that charset it is written as UTF-8
    /// and the `Content-Type` charset is rewritten so the client decodes it correctly.
    mutating func encodeBody(_ text: String, originalBody: Data) -> Data {
        let declared = BodyText.declaredCharset(contentType: contentType, body: originalBody)
        let encoded = BodyText.encode(text, contentType: contentType, originalBody: originalBody)
        if encoded.charset == nil, let declared, !BodyText.isUTF8(declared) {
            if let i = firstIndex(where: { $0.name.lowercased() == "content-type" }) {
                self[i] = HeaderPair(name: self[i].name,
                                     value: BodyText.replacingCharset(in: self[i].value, with: "utf-8"))
            }
        }
        return encoded.data
    }
}
