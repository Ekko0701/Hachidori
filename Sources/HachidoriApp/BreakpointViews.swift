import SwiftUI
import UniformTypeIdentifiers
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
                // In a grouped Form a TextField shows its title as a leading label and
                // right-aligns the text; hide the label so each row reads as name | value.
                TextField("Name", text: $header.name, prompt: Text("Name"))
                    .labelsHidden()
                TextField("Value", text: $header.value, prompt: Text("Value"))
                    .labelsHidden()
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
    /// Whether the original body was text; a binary one can still be replaced by typed text.
    @State private var bodyWasText = true
    @State private var replacement: BodyReplacement?

    var body: some View {
        VStack(spacing: 0) {
            BreakpointTitle(title: "Paused Request", subtitle: "\(request.method)  \(request.url)")
                .environment(model)
            Divider()
            Form {
                Section("Method") { TextField("Method", text: $method) }
                Section("Headers") { HeaderRowsEditor(headers: $headers) }
                Section("Body") {
                    BodyEditor(text: $bodyText, isText: $bodyIsText, originallyText: bodyWasText,
                               byteCount: request.body.count,
                               minHeight: 140, replacement: $replacement, headers: $headers)
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
        bodyWasText = bodyIsText
        bodyText = text ?? ""
        replacement = nil
    }
    private func edited() -> EditedRequest {
        var pairs = headers.map { HeaderPair(name: $0.name, value: $0.value) }
        let body = replacement?.data
            ?? (bodyIsText ? pairs.encodeBody(bodyText, originalBody: bodyWasText ? request.body : Data())
                           : request.body)
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
    /// Whether the original body was text; a binary one can still be replaced by typed text.
    @State private var bodyWasText = true
    @State private var replacement: BodyReplacement?

    var body: some View {
        VStack(spacing: 0) {
            BreakpointTitle(title: "Paused Response", subtitle: "\(response.method)  \(response.url)")
                .environment(model)
            Divider()
            Form {
                Section("Status") { TextField("Status code", value: $statusCode, format: .number) }
                Section("Headers") { HeaderRowsEditor(headers: $headers) }
                Section("Body") {
                    BodyEditor(text: $bodyText, isText: $bodyIsText, originallyText: bodyWasText,
                               byteCount: response.body.count,
                               minHeight: 160, replacement: $replacement, headers: $headers)
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
        bodyWasText = bodyIsText
        bodyText = text ?? ""
        replacement = nil
    }
    private func edited() -> EditedResponse {
        var pairs = headers.map { HeaderPair(name: $0.name, value: $0.value) }
        let body = replacement?.data
            ?? (bodyIsText ? pairs.encodeBody(bodyText, originalBody: bodyWasText ? response.body : Data())
                           : response.body)
        return EditedResponse(statusCode: statusCode, headers: pairs, body: body)
    }
}

// MARK: - Body editing helpers

/// A file chosen to be sent in place of a paused body.
struct BodyReplacement: Equatable {
    let fileName: String
    let data: Data
}

/// Text editor for a paused body. A binary body cannot be edited as text, but it can be
/// replaced with typed text, and any body can be replaced with a file's bytes.
private struct BodyEditor: View {
    @Binding var text: String
    @Binding var isText: Bool
    let originallyText: Bool
    let byteCount: Int
    let minHeight: CGFloat
    @Binding var replacement: BodyReplacement?
    @Binding var headers: [HeaderKV]

    @State private var choosingFile = false
    @State private var readError: String?

    var body: some View {
        if let replacement {
            HStack {
                Label("Replaced with \(replacement.fileName) (\(Format.bytes(replacement.data.count)))",
                      systemImage: "doc.fill")
                    .font(.callout)
                Spacer()
                Button("Revert") { self.replacement = nil }
            }
        } else if isText {
            if !originallyText {
                HStack {
                    Label("Replacing the binary body (\(Format.bytes(byteCount))) with this text",
                          systemImage: "character.cursor.ibeam")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") {
                        isText = false
                        text = ""
                    }
                }
            }
            TextEditor(text: $text).font(.callout.monospaced()).frame(minHeight: minHeight)
        } else {
            Label("Binary body (\(Format.bytes(byteCount))). Replace it with text or a file to change it.",
                  systemImage: "doc.zipper")
                .font(.callout).foregroundStyle(.secondary)
        }
        HStack {
            if !isText && replacement == nil {
                Button {
                    text = ""
                    isText = true
                    dropContentEncoding()
                } label: { Label("Replace with Text", systemImage: "character.cursor.ibeam") }
            }
            Button {
                choosingFile = true
            } label: { Label(replacement == nil ? "Replace with File…" : "Choose Another File…",
                             systemImage: "doc.badge.arrow.up") }
            if let readError {
                Text(readError).font(.caption).foregroundStyle(.red)
            }
        }
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.item]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                replacement = BodyReplacement(fileName: url.lastPathComponent, data: data)
                readError = nil
                adjustHeaders(for: url)
            } catch {
                readError = "Couldn't read \(url.lastPathComponent): \(error.localizedDescription)"
            }
        }
    }

    /// A replacement body is sent uncompressed, so the original's compression header no longer applies.
    private func dropContentEncoding() {
        headers.removeAll { $0.name.lowercased() == "content-encoding" }
    }

    /// The file's bytes go out as they are: drop a compression header that no longer
    /// applies, and label them with the file's type when macOS knows it. Both stay
    /// editable in the header rows above.
    private func adjustHeaders(for url: URL) {
        dropContentEncoding()
        guard let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType else { return }
        if let i = headers.firstIndex(where: { $0.name.lowercased() == "content-type" }) {
            headers[i].value = mime
        } else {
            headers.append(HeaderKV(name: "Content-Type", value: mime))
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
