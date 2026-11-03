import Foundation
import ProxyCore

/// Status-class filter for the traffic list.
enum StatusFilter: String, CaseIterable, Identifiable {
    case all, informational, success, redirect, clientError, serverError, failed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Statuses"
        case .informational: return "1xx Informational"
        case .success: return "2xx Success"
        case .redirect: return "3xx Redirect"
        case .clientError: return "4xx Client Error"
        case .serverError: return "5xx Server Error"
        case .failed: return "Failed (no response)"
        }
    }

    var shortTitle: String {
        switch self {
        case .all: return "Status"
        case .informational: return "1xx"
        case .success: return "2xx"
        case .redirect: return "3xx"
        case .clientError: return "4xx"
        case .serverError: return "5xx"
        case .failed: return "Failed"
        }
    }

    func matches(_ tx: CapturedTransaction) -> Bool {
        switch self {
        case .all: return true
        case .failed: return tx.isFailure
        case .informational: return tx.statusClass == 1
        case .success: return tx.statusClass == 2
        case .redirect: return tx.statusClass == 3
        case .clientError: return tx.statusClass == 4
        case .serverError: return tx.statusClass == 5
        }
    }
}

/// One row of the traffic table: either a transaction or a host group
/// (grouped mode) whose `children` are that host's transactions.
struct TrafficRow: Identifiable {
    let id: String
    let host: String
    let transaction: CapturedTransaction?
    let children: [TrafficRow]?

    init(transaction: CapturedTransaction) {
        self.id = TrafficRow.transactionRowID(transaction.id)
        self.host = transaction.host
        self.transaction = transaction
        self.children = nil
    }

    init(host: String, transactions: [CapturedTransaction]) {
        self.id = TrafficRow.hostRowID(host)
        self.host = host
        self.transaction = nil
        self.children = transactions.map(TrafficRow.init(transaction:))
    }

    var isGroup: Bool { transaction == nil }
    var count: Int { children?.count ?? 0 }
    var failureCount: Int { children?.filter { $0.transaction?.isFailure == true }.count ?? 0 }
    var totalBytes: Int { children?.reduce(0) { $0 + ($1.transaction?.responseByteCount ?? 0) } ?? 0 }

    static func transactionRowID(_ id: CapturedTransaction.ID) -> String { "tx:" + id.uuidString }
    static func hostRowID(_ host: String) -> String { "host:" + host }
    static func transactionID(_ rowID: String) -> CapturedTransaction.ID? {
        guard rowID.hasPrefix("tx:") else { return nil }
        return UUID(uuidString: String(rowID.dropFirst(3)))
    }
}

/// Builds a `curl` command that reproduces a captured request.
enum CurlExporter {
    static func command(for tx: CapturedTransaction) -> String {
        var parts = ["curl"]
        if tx.method != "GET" { parts.append("-X \(tx.method)") }
        parts.append(shellQuote(tx.absoluteURLString))
        for h in tx.requestHeaders {
            let name = h.name.lowercased()
            if name == "content-length" || name == "host" || name == "proxy-connection" { continue }
            parts.append("-H \(shellQuote("\(h.name): \(h.value)"))")
        }
        if !tx.requestBody.isEmpty {
            if let text = String(data: tx.decodedRequestBody, encoding: .utf8) {
                parts.append("--data-raw \(shellQuote(text))")
            } else {
                parts.append("--data-binary @<binary \(tx.requestBody.count) bytes>")
            }
        }
        return parts.joined(separator: " \\\n  ")
    }

    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
