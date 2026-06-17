import Foundation
import KernelHarnessKit
import Logging
import NIOCore
import NIOPosix

/// An in-process MCP (Model Context Protocol) server that exposes a
/// ``ToolRegistry`` to MCP-speaking clients over HTTP JSON-RPC.
///
/// The server binds to `127.0.0.1` on an ephemeral port by default and stays
/// out of every external network. It is designed for driving a sibling
/// subprocess — most notably the Claude Code CLI via `--mcp-config` — but
/// nothing in the implementation is CC-specific; any MCP client that speaks
/// streamable HTTP (`initialize` → `tools/list` → `tools/call`) works.
///
/// ### Example
///
/// ```swift
/// let registry = ToolRegistry()
/// registry.registerBuiltIns()
///
/// let server = MCPServer(
///     toolRegistry: registry,
///     contextFactory: {
///         ToolExecutionContext(
///             workspace: InMemoryWorkspace(),
///             permissionChecker: AllowAllPermissionChecker()
///         )
///     }
/// )
/// let handle = try await server.start()
/// // handle.url               → http://127.0.0.1:<port>/mcp
/// // handle.mcpConfigJSON     → JSON string ready for `claude --mcp-config`
/// await handle.stop()
/// ```
public final class MCPServer: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    public static let defaultHost = "127.0.0.1"
    public static let defaultServerName = "khk"

    let toolRegistry: ToolRegistry
    let contextFactory: @Sendable () -> ToolExecutionContext
    let name: String
    let serverVersion: String
    let host: String
    let port: Int
    let logger: Logger

    public init(
        toolRegistry: ToolRegistry,
        contextFactory: @escaping @Sendable () -> ToolExecutionContext,
        name: String = MCPServer.defaultServerName,
        serverVersion: String = "0.1.0",
        host: String = MCPServer.defaultHost,
        port: Int = 0,
        logger: Logger = Logger(label: "khk.mcp.server")
    ) {
        self.toolRegistry = toolRegistry
        self.contextFactory = contextFactory
        self.name = name
        self.serverVersion = serverVersion
        self.host = host
        self.port = port
        self.logger = logger
    }

    /// Bind the HTTP listener and return a handle describing the live server.
    ///
    /// Subsequent calls to ``start()`` on the same instance start an additional
    /// listener; use the returned handle to stop a specific server.
    public func start() async throws -> MCPServerHandle {
        let bridge = ToolExecutionBridge(
            registry: toolRegistry,
            contextFactory: contextFactory,
            logger: logger
        )
        let dispatcher = RPCDispatcher(
            serverName: name,
            serverVersion: serverVersion,
            protocolVersion: Self.protocolVersion,
            registry: toolRegistry,
            toolBridge: bridge,
            logger: logger
        )

        let (channel, group) = try await bindMCPHTTPServer(
            host: host,
            port: port,
            dispatcher: dispatcher,
            logger: logger
        )

        guard let localAddress = channel.localAddress, let boundPort = localAddress.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw MCPServerError.failedToBind(reason: "channel had no local address after bind")
        }

        let url = URL(string: "http://\(host):\(boundPort)/mcp")!
        let mcpConfigJSON = Self.mcpConfigJSON(serverName: name, url: url)

        let handleLogger = logger
        let shutdown: @Sendable () async -> Void = {
            try? await channel.close()
            try? await group.shutdownGracefully()
            handleLogger.debug("mcp server stopped")
        }

        logger.debug("mcp server bound", metadata: [
            "host": .string(host),
            "port": .stringConvertible(boundPort),
            "tools": .stringConvertible(toolRegistry.count),
        ])

        return MCPServerHandle(
            name: name,
            url: url,
            port: boundPort,
            mcpConfigJSON: mcpConfigJSON,
            shutdown: shutdown
        )
    }

    /// Build the JSON string accepted by `claude --mcp-config '<json>'`.
    static func mcpConfigJSON(serverName: String, url: URL) -> String {
        let envelope: [String: JSONValue] = [
            "mcpServers": .object([
                serverName: .object([
                    "type": .string("http"),
                    "url": .string(url.absoluteString),
                ])
            ])
        ]
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}

/// Errors produced while starting an ``MCPServer``.
public enum MCPServerError: Error, CustomStringConvertible, Sendable {
    case failedToBind(reason: String)

    public var description: String {
        switch self {
        case .failedToBind(let reason):
            return "MCPServer failed to bind: \(reason)"
        }
    }
}
