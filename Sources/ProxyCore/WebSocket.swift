import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

// MARK: - Upgrade detection

/// True when a request head is a WebSocket upgrade handshake.
func isWebSocketUpgrade(_ head: HTTPRequestHead) -> Bool {
    let upgrade = head.headers[canonicalForm: "Upgrade"]
        .contains { $0.lowercased() == "websocket" }
    let connectionUpgrade = head.headers[canonicalForm: "Connection"]
        .contains { $0.lowercased() == "upgrade" }
    return upgrade && connectionUpgrade
}

// MARK: - Passive frame sniffer

/// Parses a one-directional WebSocket byte stream and reports assembled
/// text/binary messages. Purely observational — it never alters the bytes the
/// proxy relays, so a parsing quirk can never break the live connection.
final class WebSocketFrameSniffer {
    private var buffer = [UInt8]()
    private var preambleSkipped: Bool
    private var fragmentKind: WebSocketMessage.Kind?
    private var fragmentPayload = [UInt8]()
    private let onMessage: (WebSocketMessage.Kind, Data) -> Void

    private let maxMessageBytes = 5 * 1024 * 1024

    init(skipPreamble: Bool, onMessage: @escaping (WebSocketMessage.Kind, Data) -> Void) {
        self.preambleSkipped = !skipPreamble
        self.onMessage = onMessage
    }

    func consume(_ bytes: [UInt8]) {
        buffer.append(contentsOf: bytes)
        if !preambleSkipped { skipPreamble() }
        if preambleSkipped { parseFrames() }
    }

    /// Drop the HTTP 101 response header block that precedes server→client frames.
    private func skipPreamble() {
        let marker: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A] // \r\n\r\n
        guard let range = firstIndex(of: marker, in: buffer) else { return }
        buffer.removeFirst(range + marker.count)
        preambleSkipped = true
    }

    private func parseFrames() {
        while buffer.count >= 2 {
            let b0 = buffer[0]
            let b1 = buffer[1]
            let fin = (b0 & 0x80) != 0
            let opcode = b0 & 0x0F
            let masked = (b1 & 0x80) != 0
            let len7 = Int(b1 & 0x7F)

            var headerLen = 2
            var payloadLen = len7
            if len7 == 126 {
                guard buffer.count >= 4 else { return }
                payloadLen = (Int(buffer[2]) << 8) | Int(buffer[3])
                headerLen = 4
            } else if len7 == 127 {
                guard buffer.count >= 10 else { return }
                payloadLen = 0
                for i in 2..<10 { payloadLen = (payloadLen << 8) | Int(buffer[i]) }
                headerLen = 10
            }

            var maskKey: [UInt8] = []
            if masked {
                guard buffer.count >= headerLen + 4 else { return }
                maskKey = Array(buffer[headerLen..<headerLen + 4])
                headerLen += 4
            }

            let total = headerLen + payloadLen
            guard payloadLen >= 0, buffer.count >= total else { return }

            var payload = Array(buffer[headerLen..<total])
            if masked {
                for i in 0..<payload.count { payload[i] ^= maskKey[i % 4] }
            }
            buffer.removeFirst(total)

            switch opcode {
            case 0x0: // continuation
                appendFragment(payload, fin: fin)
            case 0x1: // text
                handleData(payload, kind: .text, fin: fin)
            case 0x2: // binary
                handleData(payload, kind: .binary, fin: fin)
            default:
                break // control frames (close/ping/pong) — ignore for capture
            }
        }
    }

    private func handleData(_ payload: [UInt8], kind: WebSocketMessage.Kind, fin: Bool) {
        if fin {
            emit(kind, payload)
        } else {
            fragmentKind = kind
            fragmentPayload = payload
        }
    }

    private func appendFragment(_ payload: [UInt8], fin: Bool) {
        guard let kind = fragmentKind else { return }
        if fragmentPayload.count < maxMessageBytes {
            fragmentPayload.append(contentsOf: payload)
        }
        if fin {
            emit(kind, fragmentPayload)
            fragmentKind = nil
            fragmentPayload = []
        }
    }

    private func emit(_ kind: WebSocketMessage.Kind, _ bytes: [UInt8]) {
        let capped = bytes.count > maxMessageBytes ? Array(bytes.prefix(maxMessageBytes)) : bytes
        onMessage(kind, Data(capped))
    }

    private func firstIndex(of pattern: [UInt8], in data: [UInt8]) -> Int? {
        guard data.count >= pattern.count else { return nil }
        for i in 0...(data.count - pattern.count) where Array(data[i..<i + pattern.count]) == pattern {
            return i
        }
        return nil
    }
}

// MARK: - Raw byte relay

/// Forwards raw bytes to a peer channel, optionally tapping them into a sniffer.
final class GlueHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private var peer: Channel?
    private let sniffer: WebSocketFrameSniffer?

    init(sniffer: WebSocketFrameSniffer?) { self.sniffer = sniffer }

    func setPeer(_ channel: Channel) { peer = channel }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        if let sniffer, let bytes = buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) {
            sniffer.consume(bytes)
        }
        peer?.writeAndFlush(buffer, promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
        peer = nil
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
        peer?.close(promise: nil)
    }
}

// MARK: - Capture accumulator

/// Holds a WebSocket transaction and re-emits an updated snapshot (same id) each
/// time a message arrives, so the store upserts it in place.
final class WebSocketCapture: @unchecked Sendable {
    private let base: CapturedTransaction
    private var messages: [WebSocketMessage] = []
    private let lock = NSLock()
    private let onCapture: @Sendable (CapturedTransaction) -> Void

    init(base: CapturedTransaction, onCapture: @escaping @Sendable (CapturedTransaction) -> Void) {
        self.base = base
        self.onCapture = onCapture
    }

    func emitInitial() { onCapture(base) }

    func add(_ message: WebSocketMessage) {
        lock.lock()
        messages.append(message)
        var snapshot = base
        snapshot.webSocketMessages = messages
        lock.unlock()
        onCapture(snapshot)
    }

    func fail(_ reason: String) {
        var snapshot = base
        snapshot.error = reason
        onCapture(snapshot)
    }
}

// MARK: - Orchestration

enum WebSocketProxy {

    /// Establish a transparent WebSocket tunnel from an already-parsed upgrade
    /// request: relays raw bytes both ways while sniffing frames for capture.
    static func establish(
        clientChannel: Channel,
        clientHandlersToRemove: [RemovableChannelHandler],
        requestHead: HTTPRequestHead,
        requestBody: ByteBuffer,
        scheme: String, host: String, port: Int, path: String,
        useTLS: Bool,
        group: EventLoopGroup,
        clientTLSContext: NIOSSLContext?,
        started: Date,
        onCapture: @escaping @Sendable (CapturedTransaction) -> Void
    ) {
        let requestHeaderPairs = requestHead.headers.map { HeaderPair(name: $0.name, value: $0.value) }
        let base = CapturedTransaction(
            startedAt: started, method: requestHead.method.rawValue,
            scheme: scheme, host: host, port: port, path: path.isEmpty ? "/" : path,
            requestHeaders: requestHeaderPairs, statusCode: 101, isWebSocket: true)
        let capture = WebSocketCapture(base: base, onCapture: onCapture)
        capture.emitInitial()

        let serverToClient = WebSocketFrameSniffer(skipPreamble: true) { kind, data in
            capture.add(WebSocketMessage(direction: .received, kind: kind, payload: data))
        }
        let clientToServer = WebSocketFrameSniffer(skipPreamble: false) { kind, data in
            capture.add(WebSocketMessage(direction: .sent, kind: kind, payload: data))
        }
        let glueOrigin = GlueHandler(sniffer: serverToClient) // origin → client
        let glueClient = GlueHandler(sniffer: clientToServer) // client → origin

        let reconstructed = reconstructRequest(head: requestHead, path: path, body: requestBody)

        // Pause client reads until the raw pipeline is ready.
        try? clientChannel.syncOptions?.setOption(ChannelOptions.autoRead, value: false)

        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                if useTLS, let ctx = clientTLSContext {
                    do {
                        let serverHostname = isIPLiteral(host) ? nil : host
                        let ssl = try NIOSSLClientHandler(context: ctx, serverHostname: serverHostname)
                        return channel.pipeline.addHandler(ssl)
                            .flatMap { channel.pipeline.addHandler(glueOrigin) }
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                }
                return channel.pipeline.addHandler(glueOrigin)
            }

        bootstrap.connect(host: host, port: port).whenComplete { result in
            switch result {
            case .failure(let error):
                capture.fail("WebSocket connect failed: \(error)")
                clientChannel.close(promise: nil)

            case .success(let originChannel):
                glueOrigin.setPeer(clientChannel)
                glueClient.setPeer(originChannel)

                let removals = clientHandlersToRemove.map { clientChannel.pipeline.removeHandler($0) }
                EventLoopFuture.andAllSucceed(removals, on: clientChannel.eventLoop)
                    .flatMap { clientChannel.pipeline.addHandler(glueClient) }
                    .flatMap { clientChannel.setOption(ChannelOptions.autoRead, value: true) }
                    .whenComplete { handover in
                        switch handover {
                        case .failure(let error):
                            capture.fail("WebSocket handover failed: \(error)")
                            clientChannel.close(promise: nil)
                            originChannel.close(promise: nil)
                        case .success:
                            var buf = originChannel.allocator.buffer(capacity: reconstructed.count)
                            buf.writeBytes(reconstructed)
                            originChannel.writeAndFlush(buf, promise: nil)
                        }
                    }
            }
        }
    }

    /// Serialize the upgrade request to origin-form raw bytes for the origin.
    private static func reconstructRequest(head: HTTPRequestHead, path: String, body: ByteBuffer) -> [UInt8] {
        let requestPath = path.isEmpty ? "/" : path
        var text = "\(head.method.rawValue) \(requestPath) HTTP/1.1\r\n"
        for header in head.headers {
            text += "\(header.name): \(header.value)\r\n"
        }
        text += "\r\n"
        var bytes = Array(text.utf8)
        if let bodyBytes = body.getBytes(at: body.readerIndex, length: body.readableBytes) {
            bytes.append(contentsOf: bodyBytes)
        }
        return bytes
    }
}
