import Foundation

/// A single captured HTTP header (order-preserving; duplicates allowed).
public struct HeaderPair: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.id = UUID()
        self.name = name
        self.value = value
    }
}

/// A single WebSocket message captured within a tunnelled connection.
public struct WebSocketMessage: Sendable, Identifiable {
    public enum Direction: Sendable { case sent, received }   // sent = client → server
    public enum Kind: Sendable { case text, binary }

    public let id: UUID
    public let direction: Direction
    public let kind: Kind
    public let payload: Data
    public let timestamp: Date

    public init(direction: Direction, kind: Kind, payload: Data, timestamp: Date = Date()) {
        self.id = UUID()
        self.direction = direction
        self.kind = kind
        self.payload = payload
        self.timestamp = timestamp
    }

    public var text: String { String(data: payload, encoding: .utf8) ?? "<\(payload.count) bytes>" }
}

/// Timestamps collected while an exchange flows through the proxy.
///
/// All values are optional: a transaction that failed before reaching a given
/// phase (or that was answered locally by a rule) leaves later fields nil.
public struct TransactionTiming: Sendable, Hashable {
    /// The proxy began connecting to the origin (after any request breakpoint).
    public var connectStarted: Date?
    /// TCP (and, for HTTPS, TLS) connection to the origin established.
    public var connected: Date?
    /// The full request was flushed to the origin.
    public var requestSent: Date?
    /// The first byte of the response head arrived from the origin.
    public var firstByte: Date?
    /// The origin finished sending the response (before any response breakpoint).
    public var responseReceived: Date?
    /// The response was relayed to the client (after rules / breakpoints).
    public var completed: Date?

    public init(connectStarted: Date? = nil, connected: Date? = nil, requestSent: Date? = nil,
                firstByte: Date? = nil, responseReceived: Date? = nil, completed: Date? = nil) {
        self.connectStarted = connectStarted
        self.connected = connected
        self.requestSent = requestSent
        self.firstByte = firstByte
        self.responseReceived = responseReceived
        self.completed = completed
    }
}

/// One captured request/response exchange flowing through the proxy.
///
/// Emitted once per completed exchange in Phase 1 (buffered forwarding). Later
/// phases may switch to streaming updates with an in-flight state.
public struct CapturedTransaction: Sendable, Identifiable {
    public let id: UUID
    public var startedAt: Date
    public var duration: TimeInterval?

    // Request
    public var method: String
    public var scheme: String          // "http" | "https"
    public var host: String
    public var port: Int
    public var path: String            // origin-form path, including query
    public var requestHeaders: [HeaderPair]
    public var requestBody: Data

    // Response
    public var statusCode: Int?
    public var responseHeaders: [HeaderPair]
    public var responseBody: Data

    // Failure (transport error, unsupported scheme, etc.)
    public var error: String?

    // WebSocket (populated when this exchange upgraded to a WS tunnel).
    public var isWebSocket: Bool
    public var webSocketMessages: [WebSocketMessage]

    /// True when an override rule modified or replaced this response.
    public var wasOverridden: Bool

    /// Phase timestamps (connect / first byte / completion).
    public var timing: TransactionTiming

    /// IP address of the client that sent this request (nil when unknown).
    /// `127.0.0.1` is this Mac; anything else is a remote device on the LAN.
    public var clientAddress: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = Date(),
        duration: TimeInterval? = nil,
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        requestHeaders: [HeaderPair] = [],
        requestBody: Data = Data(),
        statusCode: Int? = nil,
        responseHeaders: [HeaderPair] = [],
        responseBody: Data = Data(),
        error: String? = nil,
        isWebSocket: Bool = false,
        webSocketMessages: [WebSocketMessage] = [],
        wasOverridden: Bool = false,
        timing: TransactionTiming = TransactionTiming(),
        clientAddress: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.error = error
        self.isWebSocket = isWebSocket
        self.webSocketMessages = webSocketMessages
        self.wasOverridden = wasOverridden
        self.timing = timing
        self.clientAddress = clientAddress
    }
}

public extension CapturedTransaction {
    /// Full absolute URL as displayed in the request list.
    var absoluteURLString: String {
        let showsPort = !((scheme == "http" && port == 80) || (scheme == "https" && port == 443))
        let authority = showsPort ? "\(host):\(port)" : host
        return "\(scheme)://\(authority)\(path)"
    }

    /// Just the path portion for compact list rows.
    var displayPath: String { path.isEmpty ? "/" : path }

    var responseByteCount: Int { responseBody.count }
    var requestByteCount: Int { requestBody.count }

    func headerValue(_ name: String, inResponse: Bool = true) -> String? {
        let source = inResponse ? responseHeaders : requestHeaders
        let lowered = name.lowercased()
        return source.first { $0.name.lowercased() == lowered }?.value
    }

    /// Category of the response body, derived from `Content-Type`.
    var contentTypeCategory: ContentCategory {
        ContentCategory(contentType: headerValue("Content-Type"))
    }

    /// Category of the request body, derived from the request `Content-Type`.
    var requestContentCategory: ContentCategory {
        ContentCategory(contentType: headerValue("Content-Type", inResponse: false))
    }

    /// Response `Content-Encoding` (lower-cased), if any.
    var responseContentEncoding: String? {
        headerValue("Content-Encoding")?.lowercased()
    }

    /// The response body with any gzip / deflate / brotli encoding removed.
    /// Falls back to the raw bytes when the encoding is unknown or decoding fails.
    var decodedResponseBody: Data {
        BodyDecoder.decode(responseBody, contentEncoding: responseContentEncoding) ?? responseBody
    }

    /// The request body with any gzip / deflate / brotli encoding removed.
    var decodedRequestBody: Data {
        BodyDecoder.decode(requestBody,
                           contentEncoding: headerValue("Content-Encoding", inResponse: false)?.lowercased())
            ?? requestBody
    }

    /// Response status class (1–5), or nil when there is no status.
    var statusClass: Int? { statusCode.map { $0 / 100 } }

    /// Whether this exchange ended in a transport-level failure (no response).
    var isFailure: Bool { error != nil && statusCode == nil }

    /// A CONNECT tunnel that failed before any request flowed through it —
    /// typically a client that does not trust the Root CA (one row per attempt).
    var isConnectError: Bool { method == "CONNECT" && isFailure }
}

public enum ContentCategory: String, Sendable, CaseIterable {
    case json, html, xml, javascript, css, image, form, text, pdf, binary, other

    public init(contentType: String?) {
        guard let ct = contentType?.lowercased() else { self = .other; return }
        if ct.contains("json") { self = .json }
        else if ct.contains("pdf") { self = .pdf }
        else if ct.contains("html") { self = .html }
        else if ct.contains("javascript") || ct.contains("ecmascript") { self = .javascript }
        else if ct.contains("css") { self = .css }
        else if ct.contains("xml") { self = .xml }
        else if ct.hasPrefix("image/") { self = .image }
        else if ct.contains("x-www-form-urlencoded") { self = .form }
        else if ct.hasPrefix("text/") { self = .text }
        else if Self.isKnownBinary(ct) { self = .binary }
        else { self = .other }
    }

    /// Media types that are never text, so the inspector opens them in Hex
    /// instead of trying to lay out megabytes of replacement characters.
    private static func isKnownBinary(_ ct: String) -> Bool {
        if ct.hasPrefix("audio/") || ct.hasPrefix("video/") || ct.hasPrefix("font/") { return true }
        let binaryApplicationTypes = ["octet-stream", "zip", "gzip", "x-tar", "x-7z", "x-rar", "x-bzip", "x-xz", "zstd",
                                      "protobuf", "grpc", "msgpack", "cbor", "wasm", "x-sqlite",
                                      "vnd.ms-fontobject", "x-font", "font-woff", "java-archive"]
        guard ct.hasPrefix("application/") else { return false }
        return binaryApplicationTypes.contains { ct.contains($0) }
    }

    /// Short label for list columns.
    public var shortLabel: String {
        switch self {
        case .json: return "JSON"
        case .html: return "HTML"
        case .xml: return "XML"
        case .javascript: return "JS"
        case .css: return "CSS"
        case .image: return "IMG"
        case .form: return "FORM"
        case .text: return "TXT"
        case .pdf: return "PDF"
        case .binary: return "BIN"
        case .other: return ""
        }
    }

    /// True for categories that are human-readable text.
    public var isTextual: Bool {
        switch self {
        case .image, .pdf, .binary, .other: return false
        default: return true
        }
    }
}
