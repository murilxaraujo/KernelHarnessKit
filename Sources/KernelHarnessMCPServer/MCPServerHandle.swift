import Foundation

/// A live ``MCPServer`` binding.
///
/// Hold onto the handle for the lifetime of the MCP session. When you're done,
/// call ``stop()`` to close the listening channel and release the underlying
/// NIO event-loop group. Dropping the handle without calling ``stop()`` leaks
/// an event-loop thread.
public struct MCPServerHandle: Sendable {
    /// The short server name that client configuration references.
    ///
    /// MCP clients (e.g. Claude Code) prefix every exposed tool with
    /// `mcp__<name>__`, so changing this changes the user-visible tool names.
    public let name: String

    /// The fully-qualified URL of the `POST /mcp` endpoint.
    public let url: URL

    /// The port the server is listening on. Useful when the server was started
    /// with `port: 0` (ephemeral).
    public let port: Int

    /// JSON config string ready to pass to `claude --mcp-config`.
    ///
    /// Shape: `{"mcpServers":{"<name>":{"type":"http","url":"<url>"}}}`.
    public let mcpConfigJSON: String

    let shutdown: @Sendable () async -> Void

    init(
        name: String,
        url: URL,
        port: Int,
        mcpConfigJSON: String,
        shutdown: @escaping @Sendable () async -> Void
    ) {
        self.name = name
        self.url = url
        self.port = port
        self.mcpConfigJSON = mcpConfigJSON
        self.shutdown = shutdown
    }

    /// Stop the server. Safe to call more than once — subsequent calls are no-ops.
    public func stop() async {
        await shutdown()
    }
}
