import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// A local MITM proxy.
///
/// Plain HTTP is forwarded and captured directly. For HTTPS, the client issues a
/// `CONNECT`; when a `CertificateAuthority` is available the proxy answers 200,
/// performs a TLS handshake with the client using a freshly-signed leaf cert,
/// then re-encrypts to the real origin — capturing the decrypted exchange in
/// between. Without a CA, `CONNECT` is reported as unsupported.
public final class ProxyServer: @unchecked Sendable {

    public let port: Int
    /// The address the proxy binds to ("127.0.0.1" = local only, "0.0.0.0" = LAN devices).
    public let host: String
    private let group: MultiThreadedEventLoopGroup
    private var serverChannel: Channel?
    private let onCapture: @Sendable (CapturedTransaction) -> Void
    private let ca: CertificateAuthority?
    private let ruleStore: RuleStore?
    private let breakpoints: BreakpointController?
    private var clientTLSContext: NIOSSLContext?

    /// The actual port the server bound to (useful when constructed with port 0).
    public var boundPort: Int? { serverChannel?.localAddress?.port }

    /// - Parameters:
    ///   - port: local listen port (default 9090).
    ///   - ca: certificate authority enabling HTTPS interception (nil disables it).
    ///   - onCapture: invoked (off the main thread) once per completed exchange.
    public init(port: Int = 9090,
                host: String = "127.0.0.1",
                ca: CertificateAuthority? = nil,
                ruleStore: RuleStore? = nil,
                breakpoints: BreakpointController? = nil,
                onCapture: @escaping @Sendable (CapturedTransaction) -> Void) {
        self.port = port
        self.host = host
        self.ca = ca
        self.ruleStore = ruleStore
        self.breakpoints = breakpoints
        self.onCapture = onCapture
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
    }

    public func start() throws {
        let capture = onCapture
        let group = self.group
        let ca = self.ca
        let ruleStore = self.ruleStore
        let breakpoints = self.breakpoints

        var clientConfig = TLSConfiguration.makeClientConfiguration()
        clientConfig.applicationProtocols = ["http/1.1"]
        let clientContext = try NIOSSLContext(configuration: clientConfig)
        self.clientTLSContext = clientContext

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let encoder = HTTPResponseEncoder()
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let proxy = ProxyRequestHandler(group: group,
                                                onCapture: capture,
                                                ca: ca,
                                                ruleStore: ruleStore,
                                                breakpoints: breakpoints,
                                                clientTLSContext: clientContext,
                                                httpEncoder: encoder,
                                                httpDecoder: decoder)
                return channel.pipeline.addHandlers([encoder, decoder, proxy])
            }
        serverChannel = try bootstrap.bind(host: host, port: port).wait()
    }

    public func stop() {
        try? serverChannel?.close().wait()
        serverChannel = nil
    }

    /// Shut the event-loop group down. Call once, when the server is no longer needed.
    public func shutdown() {
        stop()
        try? group.syncShutdownGracefully()
    }
}

// MARK: - Inbound (client-facing) handler for the first request on a connection

/// Handles the first request line on a client connection: a plain-HTTP proxy
/// request is forwarded directly; a `CONNECT` triggers TLS interception.
final class ProxyRequestHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let group: EventLoopGroup
    private let onCapture: @Sendable (CapturedTransaction) -> Void
    private let ca: CertificateAuthority?
    private let ruleStore: RuleStore?
    private let breakpoints: BreakpointController?
    private let clientTLSContext: NIOSSLContext?
    private let httpEncoder: HTTPResponseEncoder
    private let httpDecoder: ByteToMessageHandler<HTTPRequestDecoder>

    private var head: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private var startedAt = Date()

    init(group: EventLoopGroup,
         onCapture: @escaping @Sendable (CapturedTransaction) -> Void,
         ca: CertificateAuthority?,
         ruleStore: RuleStore?,
         breakpoints: BreakpointController?,
         clientTLSContext: NIOSSLContext?,
         httpEncoder: HTTPResponseEncoder,
         httpDecoder: ByteToMessageHandler<HTTPRequestDecoder>) {
        self.group = group
        self.onCapture = onCapture
        self.ca = ca
        self.ruleStore = ruleStore
        self.breakpoints = breakpoints
        self.clientTLSContext = clientTLSContext
        self.httpEncoder = httpEncoder
        self.httpDecoder = httpDecoder
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.bodyBuffer.clear()
            self.startedAt = Date()
        case .body(var chunk):
            bodyBuffer.writeBuffer(&chunk)
        case .end:
            guard let head = self.head else { return }
            handleCompletedRequest(context: context, head: head)
        }
    }

    private func handleCompletedRequest(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let channel = context.channel
        let started = startedAt

        if head.method == .CONNECT {
            let (host, port) = Target.splitHostPort(head.uri, defaultPort: 443)
            if ca != nil {
                startTLSInterception(context: context, host: host, port: port)
            } else {
                respondUnsupportedConnect(context: context)
                onCapture(CapturedTransaction(
                    startedAt: started, duration: Date().timeIntervalSince(started),
                    method: "CONNECT", scheme: "https", host: host, port: port, path: "",
                    requestHeaders: headerPairs(head.headers),
                    error: "HTTPS interception disabled (no certificate authority)."))
            }
            return
        }

        // Serve the Root CA to on-device browsers over plain HTTP (before trust exists).
        // Reached either via the proxy as `http://hachidori.local/...`, or by opening the
        // proxy's own address directly (`http://<mac-ip>:9090/`), which arrives as an
        // origin-form request — something a real proxy client never sends.
        let isOriginForm = head.uri.hasPrefix("/")
        if let ca = self.ca, isOriginForm || Target(from: head)?.host == "hachidori.local" {
            let hostHeader = head.headers.first(name: "Host") ?? "hachidori.local"
            let (portalHost, portalPort) = Target.splitHostPort(hostHeader, defaultPort: 80)
            let path = isOriginForm ? head.uri : (Target(from: head)?.path ?? "/")
            RequestForwarder.serveCAPortal(to: channel, path: path, ca: ca)
            onCapture(CapturedTransaction(
                startedAt: started, duration: Date().timeIntervalSince(started),
                method: head.method.rawValue, scheme: "http", host: portalHost, port: portalPort,
                path: path, statusCode: 200))
            return
        }

        guard let target = Target(from: head) else {
            respondError(context: context, status: .badRequest, message: "Cannot resolve target host")
            return
        }

        if isWebSocketUpgrade(head) {
            WebSocketProxy.establish(
                clientChannel: channel,
                clientHandlersToRemove: [httpDecoder, httpEncoder, self],
                requestHead: head, requestBody: bodyBuffer,
                scheme: target.scheme == "https" ? "wss" : "ws",
                host: target.host, port: target.port, path: target.path,
                useTLS: target.scheme == "https",
                group: group, clientTLSContext: clientTLSContext,
                started: started, onCapture: onCapture)
            return
        }

        RequestForwarder.forward(
            group: group, clientTLSContext: clientTLSContext,
            ruleStore: ruleStore, breakpoints: breakpoints,
            scheme: target.scheme, host: target.host, port: target.port, path: target.path,
            method: head.method, originHeaders: head.headers,
            body: bodyBuffer, requestBody: Data(bodyBuffer.readableBytesView),
            inbound: channel, started: started, onCapture: onCapture)
    }

    // MARK: TLS interception setup

    private func startTLSInterception(context: ChannelHandlerContext, host: String, port: Int) {
        let channel = context.channel

        // Pause reads until the TLS pipeline is in place, so the client's
        // ClientHello can't reach the plaintext HTTP decoder (which would answer
        // in cleartext and break the handshake).
        try? channel.syncOptions?.setOption(ChannelOptions.autoRead, value: false)

        var okHead = HTTPResponseHead(version: .http1_1,
                                      status: .custom(code: 200, reasonPhrase: "Connection Established"))
        // Prevent the encoder from adding chunked framing (whose terminator bytes
        // would corrupt the start of the tunnelled TLS stream).
        okHead.headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(okHead)), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)

        reconfigurePipelineForTLS(channel: channel, host: host, port: port)
    }

    private func reconfigurePipelineForTLS(channel: Channel, host: String, port: Int) {
        guard let ca = self.ca else { return }
        let group = self.group
        let onCapture = self.onCapture
        let clientTLSContext = self.clientTLSContext
        let ruleStore = self.ruleStore
        let breakpoints = self.breakpoints
        let pipeline = channel.pipeline

        pipeline.removeHandler(self.httpDecoder)
            .flatMap { pipeline.removeHandler(self.httpEncoder) }
            .flatMap { pipeline.removeHandler(self) }
            .flatMap { () -> EventLoopFuture<Void> in
                do {
                    let sslContext = try ca.serverContext(host: host)
                    let ssl = NIOSSLServerHandler(context: sslContext)
                    let encoder = HTTPResponseEncoder()
                    let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .dropBytes))
                    let mitm = MITMHandler(group: group, onCapture: onCapture,
                                           host: host, port: port,
                                           clientTLSContext: clientTLSContext,
                                           ruleStore: ruleStore, breakpoints: breakpoints,
                                           httpEncoder: encoder, httpDecoder: decoder)
                    return pipeline.addHandlers([ssl, encoder, decoder, mitm])
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .flatMap {
                // Resume reads now that the TLS handler is installed.
                channel.setOption(ChannelOptions.autoRead, value: true)
            }
            .whenComplete { result in
                if case .failure(let error) = result {
                    onCapture(CapturedTransaction(
                        method: "CONNECT", scheme: "https", host: host, port: port, path: "",
                        error: "TLS interception setup failed: \(error.localizedDescription)"))
                    channel.close(promise: nil)
                }
            }
    }

    // MARK: direct responses

    private func respondError(context: ChannelHandlerContext, status: HTTPResponseStatus, message: String) {
        RequestForwarder.writeErrorResponse(to: context.channel, status: status, message: message)
    }

    private func respondUnsupportedConnect(context: ChannelHandlerContext) {
        RequestForwarder.writeErrorResponse(to: context.channel, status: .notImplemented,
                                            message: "Hachidori: HTTPS interception is disabled.")
    }
}

// MARK: - Decrypted-request handler inside a TLS-intercepted tunnel

/// Runs after TLS is established with the client. Each decrypted request is
/// forwarded to the fixed origin (from the original `CONNECT`) over real TLS.
final class MITMHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let group: EventLoopGroup
    private let onCapture: @Sendable (CapturedTransaction) -> Void
    private let host: String
    private let port: Int
    private let clientTLSContext: NIOSSLContext?
    private let ruleStore: RuleStore?
    private let breakpoints: BreakpointController?
    private let httpEncoder: HTTPResponseEncoder
    private let httpDecoder: ByteToMessageHandler<HTTPRequestDecoder>

    private var head: HTTPRequestHead?
    private var bodyBuffer = ByteBuffer()
    private var startedAt = Date()
    private let tunnelOpenedAt = Date()
    private var sawRequest = false
    private var reportedFailure = false

    init(group: EventLoopGroup,
         onCapture: @escaping @Sendable (CapturedTransaction) -> Void,
         host: String, port: Int,
         clientTLSContext: NIOSSLContext?,
         ruleStore: RuleStore?,
         breakpoints: BreakpointController?,
         httpEncoder: HTTPResponseEncoder,
         httpDecoder: ByteToMessageHandler<HTTPRequestDecoder>) {
        self.group = group
        self.onCapture = onCapture
        self.host = host
        self.port = port
        self.clientTLSContext = clientTLSContext
        self.ruleStore = ruleStore
        self.breakpoints = breakpoints
        self.httpEncoder = httpEncoder
        self.httpDecoder = httpDecoder
    }

    /// A TLS failure before any decrypted request means the client rejected our
    /// leaf certificate (CA not trusted / pinning) or the handshake broke. Without
    /// this the tunnel would vanish silently and the UI would show nothing.
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !sawRequest && !reportedFailure {
            reportedFailure = true
            let detail = String(describing: error)
            let hint: String
            if detail.lowercased().contains("certificate") || detail.lowercased().contains("unknown ca")
                || detail.lowercased().contains("alert") {
                hint = "Client rejected the Hachidori certificate — is the Root CA installed and fully trusted on the device, or does the app pin certificates?"
            } else {
                hint = "TLS handshake with client failed."
            }
            onCapture(CapturedTransaction(
                startedAt: tunnelOpenedAt, duration: Date().timeIntervalSince(tunnelOpenedAt),
                method: "CONNECT", scheme: "https", host: host, port: port, path: "",
                error: "\(hint) (\(detail))"))
        }
        context.close(promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            self.bodyBuffer.clear()
            self.startedAt = Date()
            self.sawRequest = true
        case .body(var chunk):
            bodyBuffer.writeBuffer(&chunk)
        case .end:
            guard let head = self.head else { return }
            let path = head.uri.isEmpty ? "/" : head.uri

            if isWebSocketUpgrade(head) {
                WebSocketProxy.establish(
                    clientChannel: context.channel,
                    clientHandlersToRemove: [httpDecoder, httpEncoder, self],
                    requestHead: head, requestBody: bodyBuffer,
                    scheme: "wss", host: host, port: port, path: path,
                    useTLS: true,
                    group: group, clientTLSContext: clientTLSContext,
                    started: startedAt, onCapture: onCapture)
                return
            }

            RequestForwarder.forward(
                group: group, clientTLSContext: clientTLSContext,
                ruleStore: ruleStore, breakpoints: breakpoints,
                scheme: "https", host: host, port: port, path: path,
                method: head.method, originHeaders: head.headers,
                body: bodyBuffer, requestBody: Data(bodyBuffer.readableBytesView),
                inbound: context.channel, started: startedAt, onCapture: onCapture)
        }
    }
}

// MARK: - Shared forwarding

enum RequestForwarder {

    static func forward(
        group: EventLoopGroup,
        clientTLSContext: NIOSSLContext?,
        ruleStore: RuleStore?,
        breakpoints: BreakpointController?,
        scheme: String, host: String, port: Int, path: String,
        method: HTTPMethod, originHeaders: HTTPHeaders,
        body: ByteBuffer, requestBody: Data,
        inbound: Channel, started: Date,
        onCapture: @escaping @Sendable (CapturedTransaction) -> Void
    ) {
        let useTLS = (scheme == "https")
        let requestHeaderPairs = headerPairs(originHeaders)
        let absoluteURL = "\(scheme)://\(host)\(path.isEmpty ? "/" : path)"
        let matchedRule = ruleStore?.firstMatch(method: method.rawValue, url: absoluteURL)
        let rewriteRule = (matchedRule?.respondLocally == true) ? nil : matchedRule
        let collector = ResponseCollector()

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                if useTLS, let ctx = clientTLSContext {
                    do {
                        let serverHostname = isIPLiteral(host) ? nil : host
                        let ssl = try NIOSSLClientHandler(context: ctx, serverHostname: serverHostname)
                        return channel.pipeline.addHandler(ssl)
                            .flatMap { channel.pipeline.addHTTPClientHandlers() }
                            .flatMap { channel.pipeline.addHandler(collector) }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHTTPClientHandlers()
                    .flatMap { channel.pipeline.addHandler(collector) }
            }

        func capture(status: Int?, responseHeaders: [HeaderPair], responseBody: Data,
                     error: String?, overridden: Bool = false, timing: TransactionTiming = TransactionTiming()) {
            var timing = timing
            let now = Date()
            timing.completed = now
            onCapture(CapturedTransaction(
                startedAt: started, duration: now.timeIntervalSince(started),
                method: method.rawValue, scheme: scheme, host: host, port: port, path: path,
                requestHeaders: requestHeaderPairs, requestBody: requestBody,
                statusCode: status, responseHeaders: responseHeaders, responseBody: responseBody,
                error: error, wasOverridden: overridden, timing: timing))
        }

        // Map Local: a matching rule returns a canned response without contacting the origin.
        if let rule = matchedRule, rule.respondLocally {
            let response = makeLocalResponse(rule, allocator: inbound.allocator)
            relayResponse(response, to: inbound)
            capture(status: Int(response.head.status.code),
                    responseHeaders: headerPairs(response.head.headers),
                    responseBody: Data(response.body.readableBytesView),
                    error: nil, overridden: true)
            return
        }

        func proceed(reqMethod: HTTPMethod, reqHeaders: HTTPHeaders, reqBody: ByteBuffer) {
            var timing = TransactionTiming(connectStarted: Date())
            bootstrap.connect(host: host, port: port).whenComplete { result in
                switch result {
                case .failure(let error):
                    writeErrorResponse(to: inbound, status: .badGateway, message: "Connect failed: \(error)")
                    capture(status: nil, responseHeaders: [], responseBody: Data(),
                            error: "Connect failed: \(error)", timing: timing)

                case .success(let outbound):
                    timing.connected = Date()
                    var outHead = HTTPRequestHead(version: .http1_1, method: reqMethod, uri: path)
                    outHead.headers = reqHeaders
                    if outHead.headers.first(name: "Host") == nil {
                        outHead.headers.add(name: "Host", value: host)
                    }
                    outbound.write(HTTPClientRequestPart.head(outHead), promise: nil)
                    if reqBody.readableBytes > 0 {
                        outbound.write(HTTPClientRequestPart.body(.byteBuffer(reqBody)), promise: nil)
                    }
                    let sent = outbound.eventLoop.makePromise(of: Void.self)
                    sent.futureResult.whenComplete { _ in timing.requestSent = Date() }
                    outbound.writeAndFlush(HTTPClientRequestPart.end(nil), promise: sent)

                    collector.onComplete = { captured in
                        outbound.close(promise: nil)
                        timing.firstByte = collector.firstByteAt
                        timing.responseReceived = Date()
                        let finalTiming = timing     // immutable snapshot for breakpoint callbacks
                        switch captured {
                        case .failure(let error):
                            writeErrorResponse(to: inbound, status: .badGateway, message: "Upstream error: \(error)")
                            capture(status: nil, responseHeaders: [], responseBody: Data(),
                                    error: "Upstream error: \(error)", timing: finalTiming)
                        case .success(let raw):
                            let response = rewriteRule.map { applyRule($0, to: raw, allocator: inbound.allocator) } ?? raw

                            func deliver(_ finalResponse: CollectedResponse, edited: Bool) {
                                relayResponse(finalResponse, to: inbound)
                                capture(status: Int(finalResponse.head.status.code),
                                        responseHeaders: headerPairs(finalResponse.head.headers),
                                        responseBody: Data(finalResponse.body.readableBytesView),
                                        error: nil, overridden: edited || (rewriteRule != nil),
                                        timing: finalTiming)
                            }

                            // Response breakpoint: hold until the user edits / passes / aborts.
                            if let bp = breakpoints, bp.shouldBreakResponse(url: absoluteURL) {
                                let editable = decodedForEditing(response)
                                let paused = PausedResponse(
                                    method: method.rawValue, url: absoluteURL,
                                    statusCode: Int(response.head.status.code),
                                    headers: editable.headers,
                                    body: editable.body)
                                bp.pauseResponse(paused) { decision in
                                    switch decision {
                                    case .abort:
                                        capture(status: nil, responseHeaders: [], responseBody: Data(),
                                                error: "Aborted at response breakpoint", timing: finalTiming)
                                        inbound.close(promise: nil)
                                    case .send(let edited):
                                        if let edited {
                                            deliver(buildEditedResponse(edited, allocator: inbound.allocator), edited: true)
                                        } else {
                                            deliver(response, edited: false)
                                        }
                                    }
                                }
                            } else {
                                deliver(response, edited: false)
                            }
                        }
                    }
                }
            }
        }

        // Request breakpoint: hold before contacting the origin.
        if let bp = breakpoints, bp.shouldBreakRequest(url: absoluteURL) {
            let pausedRequest = PausedRequest(method: method.rawValue, url: absoluteURL,
                                              headers: requestHeaderPairs, body: requestBody)
            bp.pauseRequest(pausedRequest) { decision in
                switch decision {
                case .abort:
                    capture(status: nil, responseHeaders: [], responseBody: Data(),
                            error: "Aborted at request breakpoint")
                    inbound.close(promise: nil)
                case .proceed(let edited):
                    if let edited {
                        var headers = HTTPHeaders()
                        for pair in edited.headers where !pair.name.isEmpty {
                            headers.add(name: pair.name, value: pair.value)
                        }
                        if headers.first(name: "Host") == nil {
                            headers.add(name: "Host", value: host)
                        }
                        var buffer = inbound.allocator.buffer(capacity: edited.body.count)
                        buffer.writeBytes(edited.body)
                        proceed(reqMethod: httpMethod(from: edited.method), reqHeaders: headers, reqBody: buffer)
                    } else {
                        proceed(reqMethod: method, reqHeaders: originHeaders, reqBody: body)
                    }
                }
            }
        } else {
            proceed(reqMethod: method, reqHeaders: originHeaders, reqBody: body)
        }
    }

    static func relayResponse(_ response: CollectedResponse, to channel: Channel) {
        var headers = response.head.headers
        headers.remove(name: "Transfer-Encoding")
        headers.replaceOrAdd(name: "Content-Length", value: String(response.body.readableBytes))
        var head = response.head
        head.headers = headers

        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        if response.body.readableBytes > 0 {
            channel.write(HTTPServerResponsePart.body(.byteBuffer(response.body)), promise: nil)
        }
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }

    /// Build a canned response for a Map Local rule (no origin contact).
    static func makeLocalResponse(_ rule: OverrideRule, allocator: ByteBufferAllocator) -> CollectedResponse {
        let bodyData = Data(rule.body.utf8)
        var headers = HTTPHeaders()
        if !rule.contentType.isEmpty { headers.add(name: "Content-Type", value: rule.contentType) }
        for header in rule.extraHeaders where !header.name.isEmpty {
            headers.add(name: header.name, value: header.value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(bodyData.count))
        let code = rule.overrideStatus ? rule.statusCode : 200
        let head = HTTPResponseHead(version: .http1_1,
                                    status: HTTPResponseStatus(statusCode: code), headers: headers)
        var buffer = allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)
        return CollectedResponse(head: head, body: buffer)
    }

    /// Apply a rewrite rule to a real upstream response (status / headers / body).
    static func applyRule(_ rule: OverrideRule, to response: CollectedResponse,
                          allocator: ByteBufferAllocator) -> CollectedResponse {
        var head = response.head
        var body = response.body
        if rule.overrideStatus {
            head.status = HTTPResponseStatus(statusCode: rule.statusCode)
        }
        for header in rule.extraHeaders where !header.name.isEmpty {
            head.headers.replaceOrAdd(name: header.name, value: header.value)
        }
        if rule.overrideBody {
            let bodyData = Data(rule.body.utf8)
            var buffer = allocator.buffer(capacity: bodyData.count)
            buffer.writeBytes(bodyData)
            body = buffer
            if !rule.contentType.isEmpty {
                head.headers.replaceOrAdd(name: "Content-Type", value: rule.contentType)
            }
            // The replacement body is plain text: drop the origin's compression
            // marker unless the rule itself sets one, or the client would try to
            // gunzip plain bytes and fail.
            let ruleSetsEncoding = rule.extraHeaders.contains { $0.name.lowercased() == "content-encoding" }
            if !ruleSetsEncoding {
                head.headers.remove(name: "Content-Encoding")
            }
        }
        return CollectedResponse(head: head, body: body)
    }

    /// The response as shown in the breakpoint editor: body decoded (gzip/deflate/br)
    /// and `Content-Encoding` dropped so the user edits — and resends — plain text.
    /// When decoding fails the response is shown unchanged.
    static func decodedForEditing(_ response: CollectedResponse) -> (headers: [HeaderPair], body: Data) {
        let raw = Data(response.body.readableBytesView)
        let encoding = response.head.headers.first(name: "Content-Encoding")?.lowercased()
        guard let decoded = BodyDecoder.decode(raw, contentEncoding: encoding) else {
            return (headerPairs(response.head.headers), raw)
        }
        var headers = response.head.headers
        headers.remove(name: "Content-Encoding")
        return (headerPairs(headers), decoded)
    }

    /// Build a response from a user-edited breakpoint result.
    static func buildEditedResponse(_ edited: EditedResponse, allocator: ByteBufferAllocator) -> CollectedResponse {
        var headers = HTTPHeaders()
        for header in edited.headers where !header.name.isEmpty {
            // Content-Length is recomputed in relayResponse; skip stale framing headers.
            if header.name.lowercased() == "content-length" || header.name.lowercased() == "transfer-encoding" { continue }
            headers.add(name: header.name, value: header.value)
        }
        let head = HTTPResponseHead(version: .http1_1,
                                    status: HTTPResponseStatus(statusCode: edited.statusCode), headers: headers)
        var buffer = allocator.buffer(capacity: edited.body.count)
        buffer.writeBytes(edited.body)
        return CollectedResponse(head: head, body: buffer)
    }

    static func writeErrorResponse(to channel: Channel, status: HTTPResponseStatus, message: String) {
        var headers = HTTPHeaders()
        let bytes = Array(message.utf8)
        headers.add(name: "Content-Length", value: String(bytes.count))
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }

    /// Landing portal for on-device CA install (`http://hachidori.local` via the proxy,
    /// or `http://<mac-ip>:<port>/` directly). Links are relative so both work.
    /// Routes by path: `.mobileconfig` (iOS profile), `.crt` (DER), else an HTML index.
    static func serveCAPortal(to channel: Channel, path: String, ca: CertificateAuthority) {
        let route = (path.split(separator: "?").first.map(String.init) ?? path).lowercased()
        if route.contains("mobileconfig") {
            writeBody(to: channel, data: ca.mobileConfigData(),
                      contentType: "application/x-apple-aspen-config",
                      filename: "Hachidori.mobileconfig")
        } else if route.contains(".crt") || route.contains(".cer") || route.contains(".pem") {
            writeBody(to: channel, data: ca.rootCertificateDER,
                      contentType: "application/x-x509-ca-cert",
                      filename: "HachidoriCA.crt")
        } else {
            writeBody(to: channel, data: Data(caPortalHTML.utf8),
                      contentType: "text/html; charset=utf-8", filename: nil)
        }
    }

    private static let caPortalHTML = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>Hachidori CA</title></head>
    <body style="font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:2rem auto;padding:0 1rem">
    <h2>Install Hachidori Root CA</h2>
    <p>Install the certificate, then <b>trust</b> it, to decrypt HTTPS traffic.</p>
    <p><a href="/hachidori.mobileconfig" style="font-size:1.1rem">📱 iOS profile (.mobileconfig)</a><br>
    <small>After install: Settings → General → About → Certificate Trust Settings → enable full trust.</small></p>
    <p><a href="/ca.crt" style="font-size:1.1rem">🤖 Android / other (.crt)</a><br>
    <small>Install as a CA certificate in system settings.</small></p>
    </body></html>
    """

    private static func writeBody(to channel: Channel, data: Data, contentType: String, filename: String?) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(data.count))
        if let filename {
            headers.add(name: "Content-Disposition", value: "attachment; filename=\"\(filename)\"")
        }
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        var buf = channel.allocator.buffer(capacity: data.count)
        buf.writeBytes(data)
        channel.write(HTTPServerResponsePart.head(head), promise: nil)
        channel.write(HTTPServerResponsePart.body(.byteBuffer(buf)), promise: nil)
        channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
    }
}

// MARK: - Outbound (origin-facing) response collector

struct CollectedResponse {
    var head: HTTPResponseHead
    var body: ByteBuffer
}

/// Buffers a full upstream response and reports it via `onComplete`.
final class ResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    var onComplete: ((Result<CollectedResponse, Error>) -> Void)?
    /// When the response head arrived (time-to-first-byte marker).
    private(set) var firstByteAt: Date?
    private var head: HTTPResponseHead?
    private var body = ByteBuffer()
    private var finished = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            if firstByteAt == nil { firstByteAt = Date() }
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            finish(.success(CollectedResponse(head: head ?? HTTPResponseHead(version: .http1_1, status: .ok),
                                              body: body)))
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(.failure(error))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if !finished {
            if let head {
                finish(.success(CollectedResponse(head: head, body: body)))
            } else {
                finish(.failure(ProxyError.connectionClosedBeforeResponse))
            }
        }
    }

    private func finish(_ result: Result<CollectedResponse, Error>) {
        guard !finished else { return }
        finished = true
        onComplete?(result)
    }
}

enum ProxyError: Error {
    case connectionClosedBeforeResponse
}

// MARK: - Target resolution

/// Resolved origin destination for a proxied request.
struct Target {
    let scheme: String
    let host: String
    let port: Int
    let path: String

    /// Resolve from an absolute-form proxy request line, falling back to the Host header.
    init?(from head: HTTPRequestHead) {
        if let comps = URLComponents(string: head.uri), let host = comps.host {
            self.scheme = comps.scheme ?? "http"
            self.host = host
            self.port = comps.port ?? (self.scheme == "https" ? 443 : 80)
            var p = comps.percentEncodedPath.isEmpty ? "/" : comps.percentEncodedPath
            if let q = comps.percentEncodedQuery { p += "?\(q)" }
            self.path = p
            return
        }
        guard let hostHeader = head.headers.first(name: "Host") else { return nil }
        let (h, prt) = Target.splitHostPort(hostHeader, defaultPort: 80)
        self.scheme = "http"
        self.host = h
        self.port = prt
        self.path = head.uri.isEmpty ? "/" : head.uri
    }

    static func splitHostPort(_ value: String, defaultPort: Int) -> (String, Int) {
        if let colon = value.lastIndex(of: ":"),
           let p = Int(value[value.index(after: colon)...]) {
            return (String(value[..<colon]), p)
        }
        return (value, defaultPort)
    }
}

// MARK: - Helpers

private func headerPairs(_ headers: HTTPHeaders) -> [HeaderPair] {
    headers.map { HeaderPair(name: $0.name, value: $0.value) }
}

/// Map an HTTP method string (e.g. from an edited breakpoint) to `HTTPMethod`.
func httpMethod(from string: String) -> HTTPMethod {
    switch string.uppercased() {
    case "GET": return .GET
    case "POST": return .POST
    case "PUT": return .PUT
    case "DELETE": return .DELETE
    case "PATCH": return .PATCH
    case "HEAD": return .HEAD
    case "OPTIONS": return .OPTIONS
    default: return .RAW(value: string)
    }
}

/// True when `host` is an IPv4/IPv6 literal (SNI must be omitted for these).
func isIPLiteral(_ host: String) -> Bool {
    if host.contains(":") { return true } // IPv6
    let parts = host.split(separator: ".")
    return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
}
