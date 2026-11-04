import SwiftUI
import ProxyCore

/// One phase of a request's life, derived from `TransactionTiming`.
struct TimingPhase: Identifiable {
    let name: String
    let detail: String
    let start: Date
    let end: Date
    let color: Color
    var id: String { name }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

enum TimingPhases {
    static func phases(for tx: CapturedTransaction) -> [TimingPhase] {
        let t = tx.timing
        var out: [TimingPhase] = []
        func add(_ name: String, _ detail: String, _ a: Date?, _ b: Date?, _ color: Color) {
            guard let a, let b, b >= a else { return }
            out.append(TimingPhase(name: name, detail: detail, start: a, end: b, color: color))
        }
        add("Queued", "Rule matching / request breakpoint", tx.startedAt, t.connectStarted, .gray)
        add("Connect", tx.scheme == "https" ? "TCP + TLS handshake to origin" : "TCP connect to origin",
            t.connectStarted, t.connected, .purple)
        add("Send", "Request written to origin", t.connected, t.requestSent, .blue)
        add("Wait", "Time to first byte (server think time)", t.requestSent, t.firstByte, .orange)
        add("Download", "Response body received", t.firstByte, t.responseReceived, .green)
        add("Relay", "Rewrite / response breakpoint / send to client", t.responseReceived, t.completed, .teal)
        return out
    }

    static func timeToFirstByte(_ tx: CapturedTransaction) -> TimeInterval? {
        guard let sent = tx.timing.requestSent, let first = tx.timing.firstByte else { return nil }
        return first.timeIntervalSince(sent)
    }
}

/// Waterfall of the request's phases plus absolute timestamps.
struct TimingPane: View {
    let tx: CapturedTransaction

    private var phases: [TimingPhase] { TimingPhases.phases(for: tx) }
    private var origin: Date { tx.startedAt }
    private var end: Date { tx.timing.completed ?? tx.startedAt.addingTimeInterval(tx.duration ?? 0) }
    private var total: TimeInterval { max(end.timeIntervalSince(origin), 0.0001) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if phases.isEmpty {
                    ContentUnavailableView("No Timing Data",
                                           systemImage: "clock",
                                           description: Text(emptyReason))
                } else {
                    waterfall
                    Divider()
                    breakdown
                }
                Divider()
                timestamps
            }
            .padding(12)
        }
    }

    private var emptyReason: String {
        if tx.wasOverridden && tx.timing.connectStarted == nil {
            return "This response was served locally by a rule, so the origin was never contacted."
        }
        if tx.isWebSocket { return "WebSocket tunnels are relayed transparently and have no phase timing." }
        return "The request failed before any phase completed."
    }

    private var waterfall: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Waterfall").font(.headline)
                Spacer()
                Text("Total \(Format.milliseconds(total))")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Format.durationColor(total))
            }
            VStack(spacing: 4) {
                ForEach(phases) { phase in
                    HStack(spacing: 8) {
                        Text(phase.name)
                            .font(.caption.weight(.medium))
                            .frame(width: 70, alignment: .trailing)
                        GeometryReader { geo in
                            let width = geo.size.width
                            let x = CGFloat(phase.start.timeIntervalSince(origin) / total) * width
                            let w = max(CGFloat(phase.duration / total) * width, 2)
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color(nsColor: .quaternarySystemFill))
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(phase.color.gradient)
                                    .frame(width: min(w, width - x))
                                    .offset(x: x)
                            }
                        }
                        .frame(height: 14)
                        Text(Format.milliseconds(phase.duration))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 64, alignment: .trailing)
                    }
                    .help(phase.detail)
                }
            }
            .padding(8)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
        }
    }

    private var breakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Breakdown").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(phases) { phase in
                    GridRow {
                        HStack(spacing: 6) {
                            Circle().fill(phase.color).frame(width: 8, height: 8)
                            Text(phase.name).font(.callout.weight(.medium))
                        }
                        Text(phase.detail).font(.callout).foregroundStyle(.secondary)
                            .gridColumnAlignment(.leading)
                        Text(Format.milliseconds(phase.duration))
                            .font(.callout.monospacedDigit())
                            .gridColumnAlignment(.trailing)
                        Text(String(format: "%.0f%%", phase.duration / total * 100))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
        }
    }

    private var timestamps: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Timestamps").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                stampRow("Started", tx.startedAt)
                stampRow("Connect started", tx.timing.connectStarted)
                stampRow("Connected", tx.timing.connected)
                stampRow("Request sent", tx.timing.requestSent)
                stampRow("First byte", tx.timing.firstByte)
                stampRow("Response received", tx.timing.responseReceived)
                stampRow("Completed", tx.timing.completed)
            }
        }
    }

    @ViewBuilder
    private func stampRow(_ label: String, _ date: Date?) -> some View {
        GridRow {
            Text(label).font(.callout).foregroundStyle(.secondary)
            if let date {
                Text(Format.clock(date)).font(.callout.monospacedDigit())
                Text("+" + Format.milliseconds(date.timeIntervalSince(origin)))
                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
            } else {
                Text("—").font(.callout).foregroundStyle(.tertiary)
            }
        }
    }
}
