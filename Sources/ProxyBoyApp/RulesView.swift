import SwiftUI
import ProxyCore

/// Editor for response-override rules, presented as a sheet.
struct RulesView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selection: OverrideRule.ID?

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: $selection) {
                ForEach($model.overrideRules) { $rule in
                    HStack(spacing: 8) {
                        Toggle("", isOn: $rule.isEnabled).labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.name.isEmpty ? "Untitled" : rule.name)
                                .lineLimit(1)
                            Text(ruleSummary(rule))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .tag(rule.id)
                }
                .onDelete { model.overrideRules.remove(atOffsets: $0) }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if model.overrideRules.isEmpty {
                    ContentUnavailableView("No Rules", systemImage: "slider.horizontal.3",
                                           description: Text("Add a rule to override responses."))
                }
            }
        } detail: {
            if let id = selection,
               let index = model.overrideRules.firstIndex(where: { $0.id == id }) {
                RuleEditorView(rule: $model.overrideRules[index])
            } else {
                ContentUnavailableView("Select a Rule", systemImage: "sidebar.right",
                                       description: Text("Choose a rule to edit, or add a new one."))
            }
        }
        .frame(minWidth: 680, minHeight: 480)
        .onChange(of: model.overrideRules) { model.syncRules() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    let rule = OverrideRule()
                    model.overrideRules.append(rule)
                    selection = rule.id
                } label: { Label("Add Rule", systemImage: "plus") }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }

    private func ruleSummary(_ rule: OverrideRule) -> String {
        let match = rule.urlContains.isEmpty ? "any URL" : "…\(rule.urlContains)…"
        let action = rule.respondLocally ? "Map Local" : "Rewrite"
        return "\(rule.methodFilter.isEmpty ? "ANY" : rule.methodFilter) · \(match) · \(action)"
    }
}

struct RuleEditorView: View {
    @Binding var rule: OverrideRule

    private let methods = ["", "GET", "POST", "PUT", "PATCH", "DELETE"]

    var body: some View {
        Form {
            Section("Rule") {
                TextField("Name", text: $rule.name)
                Toggle("Enabled", isOn: $rule.isEnabled)
            }

            Section("Match") {
                Picker("Method", selection: $rule.methodFilter) {
                    ForEach(methods, id: \.self) { m in
                        Text(m.isEmpty ? "Any" : m).tag(m)
                    }
                }
                TextField("URL contains", text: $rule.urlContains,
                          prompt: Text("e.g. /api/user  (empty = all)"))
                    .autocorrectionDisabled()
            }

            Section("Response") {
                Toggle("Map Local (don't contact server)", isOn: $rule.respondLocally)

                Toggle("Override status code", isOn: $rule.overrideStatus)
                if rule.overrideStatus {
                    TextField("Status code", value: $rule.statusCode, format: .number)
                }

                Toggle(rule.respondLocally ? "Response body" : "Override response body",
                       isOn: $rule.overrideBody)
                    .disabled(rule.respondLocally)   // Map Local always uses the body below
                if rule.respondLocally || rule.overrideBody {
                    TextField("Content-Type", text: $rule.contentType)
                    TextEditor(text: $rule.body)
                        .font(.callout.monospaced())
                        .frame(minHeight: 120)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                }
            }

            Section("Extra response headers") {
                ForEach($rule.extraHeaders) { $header in
                    HStack {
                        TextField("Name", text: $header.name)
                        TextField("Value", text: $header.value)
                        Button(role: .destructive) {
                            rule.extraHeaders.removeAll { $0.id == header.id }
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                Button {
                    rule.extraHeaders.append(HeaderKV())
                } label: { Label("Add header", systemImage: "plus") }
            }
        }
        .formStyle(.grouped)
    }
}
