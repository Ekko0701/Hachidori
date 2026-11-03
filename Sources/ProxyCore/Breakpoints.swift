import Foundation

// MARK: - Request breakpoints

/// A request paused before it is forwarded to the origin.
public struct PausedRequest: Sendable, Identifiable {
    public let id: UUID
    public let method: String
    public let url: String
    public var headers: [HeaderPair]
    public var body: Data

    public init(id: UUID = UUID(), method: String, url: String,
                headers: [HeaderPair], body: Data) {
        self.id = id
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// The (possibly edited) request to send to the origin.
public struct EditedRequest: Sendable {
    public var method: String
    public var headers: [HeaderPair]
    public var body: Data

    public init(method: String, headers: [HeaderPair], body: Data) {
        self.method = method
        self.headers = headers
        self.body = body
    }
}

public enum RequestDecision: Sendable {
    case proceed(EditedRequest?)   // nil = send original
    case abort                     // drop the connection
}

// MARK: - Response breakpoints

/// A response paused before it reaches the client.
public struct PausedResponse: Sendable, Identifiable {
    public let id: UUID
    public let method: String
    public let url: String
    public var statusCode: Int
    public var headers: [HeaderPair]
    public var body: Data

    public init(id: UUID = UUID(), method: String, url: String,
                statusCode: Int, headers: [HeaderPair], body: Data) {
        self.id = id
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

/// The (possibly edited) response the user chooses to send to the client.
public struct EditedResponse: Sendable {
    public var statusCode: Int
    public var headers: [HeaderPair]
    public var body: Data

    public init(statusCode: Int, headers: [HeaderPair], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public enum ResponseDecision: Sendable {
    case send(EditedResponse?)     // nil = send original
    case abort                     // drop the connection
}

// MARK: - Pending item

/// A paused request or response awaiting the user's decision.
public struct BreakpointPending: Identifiable, @unchecked Sendable {
    public enum Kind {
        case request(PausedRequest, resume: @Sendable (RequestDecision) -> Void)
        case response(PausedResponse, resume: @Sendable (ResponseDecision) -> Void)
    }
    public let id: UUID
    public let kind: Kind

    public init(id: UUID, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

// MARK: - Controller

/// Pauses matching requests (before origin) and/or responses (before client) so
/// the user can edit or abort them. The engine calls the `shouldBreak…`/`pause…`
/// methods; the app consumes `pending` and calls each item's `resume`.
public final class BreakpointController: @unchecked Sendable {

    private let lock = NSLock()
    private var requestsEnabled = false
    private var responsesEnabled = false
    private var urlContains = ""

    public let pending: AsyncStream<BreakpointPending>
    private let continuation: AsyncStream<BreakpointPending>.Continuation

    public init() {
        (pending, continuation) = AsyncStream.makeStream()
    }

    public func configure(requestsEnabled: Bool, responsesEnabled: Bool, urlContains: String) {
        lock.lock()
        self.requestsEnabled = requestsEnabled
        self.responsesEnabled = responsesEnabled
        self.urlContains = urlContains
        lock.unlock()
    }

    public func shouldBreakRequest(url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requestsEnabled && matches(url)
    }

    public func shouldBreakResponse(url: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return responsesEnabled && matches(url)
    }

    private func matches(_ url: String) -> Bool {
        urlContains.isEmpty || url.lowercased().contains(urlContains.lowercased())
    }

    public func pauseRequest(_ request: PausedRequest,
                             resume: @escaping @Sendable (RequestDecision) -> Void) {
        continuation.yield(BreakpointPending(id: request.id, kind: .request(request, resume: resume)))
    }

    public func pauseResponse(_ response: PausedResponse,
                              resume: @escaping @Sendable (ResponseDecision) -> Void) {
        continuation.yield(BreakpointPending(id: response.id, kind: .response(response, resume: resume)))
    }
}
