import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix

/// NIO pipeline handler that drains an HTTP request, hands the body to an
/// ``RPCDispatcher``, and writes the dispatched ``MCPResponse`` back.
///
/// The handler mirrors the JSON-RPC / MCP convention the Claude Code CLI uses
/// against a `streamable-http` transport:
///
/// * `POST /mcp` with a JSON-RPC envelope → 200 + JSON body.
/// * `POST /mcp` with a `notifications/*` envelope → 202, empty body.
/// * Any other method (e.g. the `GET /mcp` SSE probe) → 405 Method Not Allowed.
///
/// Only one request is in flight per connection — this is enough for CC, which
/// opens a fresh request per RPC.
final class MCPHTTPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let dispatcher: RPCDispatcher
    private let logger: Logger

    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var keepAlive = false

    init(dispatcher: RPCDispatcher, logger: Logger) {
        self.dispatcher = dispatcher
        self.logger = logger
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            keepAlive = head.isKeepAlive
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)

        case .body(var buffer):
            if bodyBuffer != nil {
                bodyBuffer?.writeBuffer(&buffer)
            }

        case .end:
            guard let head = requestHead else { return }
            let body = bodyBuffer.map { Data($0.readableBytesView) } ?? Data()
            requestHead = nil
            bodyBuffer = nil

            let channel = context.channel
            let keepAlive = self.keepAlive
            let method = head.method
            let uri = head.uri
            let dispatcher = self.dispatcher
            let logger = self.logger

            Task {
                logger.debug("mcp http request", metadata: [
                    "method": .string(String(describing: method)),
                    "uri": .string(uri),
                    "body": .string(String(data: body, encoding: .utf8) ?? "<binary>"),
                ])
                let response: MCPResponse
                if method == .POST {
                    response = await dispatcher.handle(body: body)
                } else {
                    response = .methodNotAllowed
                }
                Self.logResponse(response, logger: logger)
                await Self.writeResponse(response, to: channel, keepAlive: keepAlive, logger: logger)
            }
        }
    }

    private static func logResponse(_ response: MCPResponse, logger: Logger) {
        switch response {
        case .json(let data):
            logger.debug("mcp http response 200", metadata: [
                "body": .string(String(data: data, encoding: .utf8) ?? "<binary>"),
            ])
        case .accepted:
            logger.debug("mcp http response 202")
        case .methodNotAllowed:
            logger.debug("mcp http response 405")
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.debug("mcp http handler error", metadata: ["error": .string(String(describing: error))])
        context.close(promise: nil)
    }

    private static func writeResponse(
        _ response: MCPResponse,
        to channel: Channel,
        keepAlive: Bool,
        logger: Logger
    ) async {
        let status: HTTPResponseStatus
        let bodyBytes: [UInt8]
        let contentType: String

        switch response {
        case .json(let data):
            status = .ok
            bodyBytes = Array(data)
            contentType = "application/json"
        case .accepted:
            status = .accepted
            bodyBytes = []
            contentType = "application/json"
        case .methodNotAllowed:
            status = .methodNotAllowed
            bodyBytes = []
            contentType = "text/plain"
        }

        var headers = HTTPHeaders()
        headers.add(name: "content-type", value: contentType)
        headers.add(name: "content-length", value: "\(bodyBytes.count)")
        if keepAlive {
            headers.add(name: "connection", value: "keep-alive")
        } else {
            headers.add(name: "connection", value: "close")
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        let buffer = channel.allocator.buffer(bytes: bodyBytes)

        do {
            try await channel.eventLoop.submit {
                channel.write(HTTPServerResponsePart.head(head), promise: nil)
                if !bodyBytes.isEmpty {
                    channel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                }
                let promise = channel.eventLoop.makePromise(of: Void.self)
                channel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: promise)
                if !keepAlive {
                    promise.futureResult.whenComplete { _ in
                        channel.close(promise: nil)
                    }
                }
            }.get()
        } catch {
            logger.debug("mcp response write failed", metadata: ["error": .string(String(describing: error))])
        }
    }
}

/// Bind an MCP HTTP server on the given host/port and return the bound channel
/// plus the event-loop group owning it. Caller is responsible for calling
/// `channel.close()` and `group.shutdownGracefully()` during shutdown.
func bindMCPHTTPServer(
    host: String,
    port: Int,
    dispatcher: RPCDispatcher,
    logger: Logger
) async throws -> (channel: Channel, group: MultiThreadedEventLoopGroup) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let bootstrap = ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.backlog, value: 64)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline(withErrorHandling: true).flatMap {
                channel.pipeline.addHandler(MCPHTTPHandler(dispatcher: dispatcher, logger: logger))
            }
        }
        .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

    do {
        let channel = try await bootstrap.bind(host: host, port: port).get()
        return (channel, group)
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
}
