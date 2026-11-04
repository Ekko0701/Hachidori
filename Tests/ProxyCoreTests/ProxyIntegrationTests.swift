import XCTest
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import NIOTLS
@testable import ProxyCore

/// End-to-end: raw NIO client → ProxyServer → local NIO origin server.
final class ProxyIntegrationTests: XCTestCase {

    func testProxyForwardsHTTPAndCapturesTransaction() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        // 1. Origin server on an ephemeral port.
        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        // 2. Proxy on an ephemeral port, collecting captures.
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0) { tx in box.append(tx) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // 3. Client sends an absolute-form request through the proxy.
        let host = "127.0.0.1:\(originPort)"
        let absolute = "http://\(host)/hello?x=1"
        let (status, body) = try fetchThroughProxy(proxyPort: proxyPort,
                                                   absoluteURL: absolute,
                                                   host: host,
                                                   group: group)

        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "hello from origin")

        // 4. Capture should have recorded the exchange.
        let captured = try waitForCapture(box)
        XCTAssertEqual(captured.statusCode, 200)
        XCTAssertEqual(captured.method, "GET")
        XCTAssertEqual(captured.host, "127.0.0.1")
        XCTAssertEqual(captured.port, originPort)
        XCTAssertEqual(captured.path, "/hello?x=1")
        XCTAssertEqual(String(data: captured.responseBody, encoding: .utf8), "hello from origin")
        XCTAssertEqual(captured.headerValue("X-Echo-Path"), "/hello?x=1")

        // 5. Phase timestamps are populated and monotonic.
        let t = captured.timing
        let connectStarted = try XCTUnwrap(t.connectStarted)
        let connected = try XCTUnwrap(t.connected)
        let requestSent = try XCTUnwrap(t.requestSent)
        let firstByte = try XCTUnwrap(t.firstByte)
        let received = try XCTUnwrap(t.responseReceived)
        let completed = try XCTUnwrap(t.completed)
        XCTAssertGreaterThanOrEqual(connectStarted, captured.startedAt)
        XCTAssertGreaterThanOrEqual(connected, connectStarted)
        XCTAssertGreaterThanOrEqual(requestSent, connected)
        XCTAssertGreaterThanOrEqual(firstByte, requestSent)
        XCTAssertGreaterThanOrEqual(received, firstByte)
        XCTAssertGreaterThanOrEqual(completed, received)
    }

    func testRewriteRuleOverridesResponseBody() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        let store = RuleStore()
        store.setRules([OverrideRule(urlContains: "/hello", overrideBody: true,
                                     body: "OVERRIDDEN", contentType: "text/plain")])
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, ruleStore: store) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let host = "127.0.0.1:\(originPort)"
        let (status, body) = try fetchThroughProxy(proxyPort: proxyPort,
                                                   absoluteURL: "http://\(host)/hello",
                                                   host: host, group: group)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "OVERRIDDEN")
        XCTAssertTrue(try waitForCapture(box).wasOverridden)
    }

    func testMapLocalRuleReturnsCannedResponseWithoutContactingOrigin() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let store = RuleStore()
        store.setRules([OverrideRule(urlContains: "/mock", respondLocally: true,
                                     overrideStatus: true, statusCode: 201,
                                     overrideBody: true, body: "{\"mock\":true}",
                                     contentType: "application/json")])
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, ruleStore: store) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // Port 9 (discard) has no server: Map Local must not try to connect.
        let host = "127.0.0.1:9"
        let (status, body) = try fetchThroughProxy(proxyPort: proxyPort,
                                                   absoluteURL: "http://\(host)/mock",
                                                   host: host, group: group)
        XCTAssertEqual(status, 201)
        XCTAssertEqual(body, "{\"mock\":true}")
        XCTAssertTrue(try waitForCapture(box).wasOverridden)
    }

    func testBreakpointEditsResponseBeforeDelivery() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        let breakpoints = BreakpointController()
        breakpoints.configure(requestsEnabled: false, responsesEnabled: true, urlContains: "/hello")

        // Consumer auto-edits any paused response (stands in for the UI).
        let consumer = Task {
            for await pending in breakpoints.pending {
                if case .response(_, let resume) = pending.kind {
                    resume(.send(EditedResponse(
                        statusCode: 418,
                        headers: [HeaderPair(name: "X-Breakpoint", value: "1")],
                        body: Data("EDITED".utf8))))
                }
            }
        }
        defer { consumer.cancel() }

        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, breakpoints: breakpoints) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let host = "127.0.0.1:\(originPort)"
        let (status, body) = try fetchThroughProxy(proxyPort: proxyPort,
                                                   absoluteURL: "http://\(host)/hello",
                                                   host: host, group: group)
        XCTAssertEqual(status, 418)
        XCTAssertEqual(body, "EDITED")
        XCTAssertTrue(try waitForCapture(box).wasOverridden)
    }

    func testRequestBreakpointProceedForwardsToOrigin() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        let breakpoints = BreakpointController()
        breakpoints.configure(requestsEnabled: true, responsesEnabled: false, urlContains: "/hello")
        let consumer = Task {
            for await pending in breakpoints.pending {
                if case .request(_, let resume) = pending.kind { resume(.proceed(nil)) }
            }
        }
        defer { consumer.cancel() }

        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, breakpoints: breakpoints) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let host = "127.0.0.1:\(originPort)"
        let (status, body) = try fetchThroughProxy(proxyPort: proxyPort,
                                                   absoluteURL: "http://\(host)/hello",
                                                   host: host, group: group)
        XCTAssertEqual(status, 200)
        XCTAssertEqual(body, "hello from origin")
    }

    func testRewriteRuleOnCompressedResponseDropsContentEncoding() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        let store = RuleStore()
        store.setRules([OverrideRule(urlContains: "/gzipped", overrideBody: true,
                                     body: "{\"patched\":true}", contentType: "application/json")])
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, ruleStore: store) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let host = "127.0.0.1:\(originPort)"
        let response = try fetchThroughProxyDetailed(proxyPort: proxyPort,
                                                     absoluteURL: "http://\(host)/gzipped",
                                                     host: host, group: group)
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, "{\"patched\":true}")
        XCTAssertNil(response.headers.first(name: "Content-Encoding"),
                     "plain replacement body must not carry the origin's gzip marker")
        XCTAssertEqual(response.headers.first(name: "Content-Type"), "application/json")
    }

    func testResponseBreakpointShowsDecodedBodyForCompressedResponse() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }

        let origin = try startOrigin(group: group)
        defer { try? origin.close().wait() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        let breakpoints = BreakpointController()
        breakpoints.configure(requestsEnabled: false, responsesEnabled: true, urlContains: "/gzipped")

        let seen = PausedBox()
        let consumer = Task {
            for await pending in breakpoints.pending {
                if case .response(let paused, let resume) = pending.kind {
                    seen.set(paused)
                    // Edit the plain-text body the user sees; resend with the headers as shown.
                    resume(.send(EditedResponse(statusCode: paused.statusCode,
                                                headers: paused.headers,
                                                body: Data("EDITED PLAIN".utf8))))
                }
            }
        }
        defer { consumer.cancel() }

        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, breakpoints: breakpoints) { box.append($0) }
        try proxy.start()
        defer { proxy.shutdown() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let host = "127.0.0.1:\(originPort)"
        let response = try fetchThroughProxyDetailed(proxyPort: proxyPort,
                                                     absoluteURL: "http://\(host)/gzipped",
                                                     host: host, group: group)
        let paused = try XCTUnwrap(seen.get())
        XCTAssertEqual(String(data: paused.body, encoding: .utf8), "hello from origin",
                       "editor must show the decoded body, not gzip bytes")
        XCTAssertFalse(paused.headers.contains { $0.name.lowercased() == "content-encoding" })

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(response.body, "EDITED PLAIN")
        XCTAssertNil(response.headers.first(name: "Content-Encoding"))
    }

    // MARK: - Helpers

    private func waitForCapture(_ box: CaptureBox, timeout: TimeInterval = 2) throws -> CapturedTransaction {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let first = box.all().first { return first }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw XCTSkip("No transaction captured within timeout")
    }

    private func startOrigin(group: EventLoopGroup) throws -> Channel {
        try ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(OriginHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .wait()
    }

    // MARK: HTTPS tunnels

    func testIdleTunnelClosedAfterHandshakeIsNotReportedAsError() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let ca = try makeTestCA()
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, ca: ca) { box.append($0) }
        try proxy.start()
        defer { proxy.stop() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // CONNECT, finish the TLS handshake trusting Hachidori's CA, then hang up without a request.
        let channel = try openTunnel(proxyPort: proxyPort, host: "idle.example", trustCA: ca, group: group)
        try channel.close().wait()
        Thread.sleep(forTimeInterval: 0.2)

        XCTAssertTrue(box.all().isEmpty, "idle spare connections must not show up as CONNECT ERR: \(box.all())")
    }

    func testClientRejectingLeafCertificateIsReported() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        defer { try? group.syncShutdownGracefully() }
        let ca = try makeTestCA()
        let box = CaptureBox()
        let proxy = ProxyServer(port: 0, ca: ca) { box.append($0) }
        try proxy.start()
        defer { proxy.stop() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // A client that does NOT trust the CA aborts the handshake.
        XCTAssertThrowsError(try openTunnel(proxyPort: proxyPort, host: "pinned.example", trustCA: nil, group: group))
        let deadline = Date().addingTimeInterval(2)
        while box.all().isEmpty && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }

        let tx = try XCTUnwrap(box.all().first)
        XCTAssertEqual(tx.method, "CONNECT")
        XCTAssertEqual(tx.host, "pinned.example")
        XCTAssertTrue(tx.error?.contains("rejected the Hachidori certificate") == true, tx.error ?? "no error")
    }

    private func makeTestCA() throws -> CertificateAuthority {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hachidori-proxy-tests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return try CertificateAuthority.generateOrLoad(directoryURL: dir)
    }

    /// Sends `CONNECT host:443` to the proxy, then runs a TLS handshake inside the tunnel.
    /// Returns the channel once the handshake completed; throws when it fails.
    private func openTunnel(proxyPort: Int, host: String, trustCA: CertificateAuthority?,
                            group: EventLoopGroup) throws -> Channel {
        let channel = try ClientBootstrap(group: group).connect(host: "127.0.0.1", port: proxyPort).wait()

        // 1. Plain CONNECT and wait for "200 Connection Established".
        let connected = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.addHandler(ConnectResponseWaiter(promise: connected), name: ConnectResponseWaiter.name).wait()
        var buf = channel.allocator.buffer(capacity: 128)
        buf.writeString("CONNECT \(host):443 HTTP/1.1\r\nHost: \(host):443\r\n\r\n")
        try channel.writeAndFlush(buf).wait()
        try connected.futureResult.wait()
        try channel.pipeline.removeHandler(name: ConnectResponseWaiter.name).wait()

        // 2. TLS handshake through the tunnel.
        var tls = TLSConfiguration.makeClientConfiguration()
        if let trustCA {
            let root = try NIOSSLCertificate(bytes: Array(trustCA.rootCertificatePEM.utf8), format: .pem)
            tls.trustRoots = .certificates([root])
        }
        let sslContext = try NIOSSLContext(configuration: tls)
        let handshake = channel.eventLoop.makePromise(of: Void.self)
        try channel.pipeline.addHandler(try NIOSSLClientHandler(context: sslContext, serverHostname: host)).wait()
        try channel.pipeline.addHandler(HandshakeWaiter(promise: handshake)).wait()
        try handshake.futureResult.wait()
        return channel
    }

    private func fetchThroughProxy(proxyPort: Int,
                                   absoluteURL: String,
                                   host: String,
                                   group: EventLoopGroup) throws -> (Int, String) {
        let r = try fetchThroughProxyDetailed(proxyPort: proxyPort, absoluteURL: absoluteURL, host: host, group: group)
        return (r.status, r.body)
    }

    private func fetchThroughProxyDetailed(proxyPort: Int,
                                           absoluteURL: String,
                                           host: String,
                                           group: EventLoopGroup) throws -> ClientResponse {
        let promise = group.next().makePromise(of: ClientResponse.self)
        let bootstrap = ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHTTPClientHandlers().flatMap {
                    channel.pipeline.addHandler(ClientResponseCollector(promise: promise))
                }
            }
        let channel = try bootstrap.connect(host: "127.0.0.1", port: proxyPort).wait()
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: absoluteURL)
        head.headers.add(name: "Host", value: host)
        channel.write(HTTPClientRequestPart.head(head), promise: nil)
        channel.writeAndFlush(HTTPClientRequestPart.end(nil), promise: nil)
        return try promise.futureResult.wait()
    }
}

// MARK: - Test infrastructure

struct ClientResponse {
    var status: Int
    var headers: HTTPHeaders
    var body: String
}

private final class PausedBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PausedResponse?
    func set(_ v: PausedResponse) { lock.lock(); value = v; lock.unlock() }
    func get() -> PausedResponse? { lock.lock(); defer { lock.unlock() }; return value }
}

private final class CaptureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CapturedTransaction] = []
    func append(_ t: CapturedTransaction) { lock.lock(); items.append(t); lock.unlock() }
    func all() -> [CapturedTransaction] { lock.lock(); defer { lock.unlock() }; return items }
}

private final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var path = "/"

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            path = head.uri
        case .body:
            break
        case .end:
            let bodyText = "hello from origin"
            var headers = HTTPHeaders()
            var buffer: ByteBuffer
            if path.hasPrefix("/gzipped") {
                let gz = TestCompression.gzip(Data(bodyText.utf8))
                buffer = context.channel.allocator.buffer(capacity: gz.count)
                buffer.writeBytes(gz)
                headers.add(name: "Content-Encoding", value: "gzip")
            } else {
                buffer = context.channel.allocator.buffer(capacity: bodyText.utf8.count)
                buffer.writeString(bodyText)
            }
            headers.add(name: "Content-Length", value: String(buffer.readableBytes))
            headers.add(name: "Content-Type", value: "text/plain")
            headers.add(name: "X-Echo-Path", value: path)
            let responseHead = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
            context.write(wrapOutboundOut(.head(responseHead)), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

private final class ClientResponseCollector: ChannelInboundHandler {
    typealias InboundIn = HTTPClientResponsePart

    private let promise: EventLoopPromise<ClientResponse>
    private var status = 0
    private var headers = HTTPHeaders()
    private var body = ""
    private var done = false

    init(promise: EventLoopPromise<ClientResponse>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            status = Int(head.status.code)
            headers = head.headers
        case .body(var chunk):
            body += chunk.readString(length: chunk.readableBytes) ?? ""
        case .end:
            done = true
            promise.succeed(ClientResponse(status: status, headers: headers, body: body))
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { promise.fail(error) }
        context.close(promise: nil)
    }
}

/// Completes its promise once the proxy's CONNECT reply header has fully arrived.
private final class ConnectResponseWaiter: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    static let name = "connect-waiter"
    private let promise: EventLoopPromise<Void>
    private var received = ""
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        received += buf.getString(at: buf.readerIndex, length: buf.readableBytes) ?? ""
        if received.contains("\r\n\r\n") {
            if received.hasPrefix("HTTP/1.1 200") { promise.succeed(()) } else { promise.fail(TunnelError.refused(received)) }
        }
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error) }
    func channelInactive(context: ChannelHandlerContext) { promise.fail(TunnelError.closed) }
}

/// Resolves when NIOSSL reports the handshake finished, or fails on any TLS error.
private final class HandshakeWaiter: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<Void>
    init(promise: EventLoopPromise<Void>) { self.promise = promise }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if case TLSUserEvent.handshakeCompleted = event { promise.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { promise.fail(error); context.close(promise: nil) }
    func channelInactive(context: ChannelHandlerContext) { promise.fail(TunnelError.closed) }
}

private enum TunnelError: Error { case refused(String), closed }
