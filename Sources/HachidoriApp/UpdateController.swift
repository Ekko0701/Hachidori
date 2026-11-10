import SwiftUI
import AppKit
import Updater

/// Looks for a newer release on GitHub and installs it when the user restarts to update.
@MainActor
@Observable
final class UpdateController {
    enum Phase: Equatable {
        case idle
        case checking
        case preparing
        case failed(String)
    }

    /// Developer ID team whose signature an update must carry.
    static let signerTeamID = "34JS69S5XZ"
    private static let checkInterval: Duration = .seconds(6 * 60 * 60)

    private(set) var available: AvailableUpdate?
    private(set) var phase: Phase = .idle
    /// Whether the update popover is open (the toolbar button and the menu command both open it).
    var isShowingUpdate = false

    /// Nil in a development build, which has no Info.plist and so no version to compare.
    let currentVersion: AppVersion?
    private let bundleIdentifier: String?
    private let checker = UpdateChecker(owner: "Ekko0701", repo: "Hachidori", appName: "Hachidori")
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        bundleIdentifier = bundle.bundleIdentifier
        currentVersion = (bundle.infoDictionary?["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
    }

    var canCheck: Bool { currentVersion != nil && bundleIdentifier != nil }

    /// Why this copy can't replace itself (run from the DMG, a read-only folder, ...).
    var installBlocker: String? { UpdateInstaller.blocker(for: Bundle.main.bundleURL) }

    /// Checks shortly after launch, then every few hours while the app runs.
    func start() {
        guard canCheck, loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            while !Task.isCancelled {
                await self?.check(userInitiated: false)
                try? await Task.sleep(for: Self.checkInterval)
            }
        }
    }

    /// A background check stays silent unless it finds something; one the user asked
    /// for always answers.
    func check(userInitiated: Bool) async {
        guard let currentVersion, phase != .checking, phase != .preparing else { return }
        phase = .checking
        do {
            let update = try await checker.check(current: currentVersion)
            phase = .idle
            available = update
            if userInitiated {
                if update != nil {
                    isShowingUpdate = true
                } else {
                    showAlert("Hachidori is up to date", "Version \(currentVersion) is the latest version.")
                }
            }
        } catch {
            phase = .idle
            if userInitiated {
                showAlert("Couldn't check for updates", error.localizedDescription)
            }
        }
    }

    /// Downloads and verifies the update, then quits so the helper can swap it in and reopen.
    /// Quitting goes through the normal path, which stops recording and restores the system proxy.
    func restartToUpdate() async {
        guard let update = available, let bundleIdentifier, phase != .preparing else { return }
        if let blocker = installBlocker {
            phase = .failed(blocker)
            return
        }
        phase = .preparing
        let installer = UpdateInstaller(installedApp: Bundle.main.bundleURL,
                                        bundleIdentifier: bundleIdentifier,
                                        signerTeamID: Self.signerTeamID)
        do {
            let staged = try await installer.prepare(update)
            do {
                try installer.launchSwap(staged)
            } catch {
                installer.discard(staged)
                throw error
            }
            NSApp.terminate(nil)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    /// Opens the DMG download in the browser, for when updating in place isn't possible.
    func downloadManually() {
        guard let available else { return }
        NSWorkspace.shared.open(available.dmgURL)
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}

/// The update popover: what's new and the Restart to Update button.
struct UpdateView: View {
    @Environment(UpdateController.self) private var updater
    @Environment(AppModel.self) private var model

    var body: some View {
        if let update = updater.available {
            VStack(alignment: .leading, spacing: 12) {
                Label("Hachidori \(update.version.description) is available",
                      systemImage: "arrow.down.circle.fill")
                    .font(.headline)
                if let current = updater.currentVersion {
                    Text("You have version \(current.description).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if !update.notes.isEmpty {
                    ScrollView {
                        Text(notes(update.notes))
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                Link("Release notes on GitHub", destination: update.releaseURL)
                    .font(.callout)

                status

                HStack {
                    if updater.installBlocker != nil || isFailed {
                        Button("Download DMG") { updater.downloadManually() }
                    }
                    Spacer()
                    Button("Later") { updater.isShowingUpdate = false }
                    Button("Restart to Update") {
                        Task { await updater.restartToUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(updater.phase == .preparing || updater.installBlocker != nil)
                }
            }
            .padding(16)
            .frame(width: 360)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var status: some View {
        if updater.phase == .preparing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Downloading and checking the update…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        } else if case .failed(let message) = updater.phase {
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        } else if let blocker = updater.installBlocker {
            Text(blocker)
                .font(.caption)
                .foregroundStyle(.orange)
        } else if model.isRecording {
            Text("Recording stops and the system proxy is restored before Hachidori restarts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var isFailed: Bool {
        if case .failed = updater.phase { return true }
        return false
    }

    private func notes(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}
