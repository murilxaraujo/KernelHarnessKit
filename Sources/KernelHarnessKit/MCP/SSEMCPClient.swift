import Foundation

/// An MCP client variant tuned for proxies that serve SSE-only responses
/// (e.g., [MCPO](https://github.com/open-webui/mcpo)).
///
/// Functionally identical to ``HTTPMCPClient`` — the wire protocol is still
/// JSON-RPC 2.0 in HTTP POSTs — but the `Accept` header is set to
/// `text/event-stream` to match server expectations.
public final class SSEMCPClient: MCPClient, @unchecked Sendable {
    private let inner: HTTPMCPClient

    public init(url: URL, headers: [String: String] = [:]) {
        var combined = headers
        combined["Accept"] = "text/event-stream"
        self.inner = HTTPMCPClient(url: url, headers: combined)
    }

    public func connect() async throws { try await inner.connect() }
    public func listTools() async throws -> [MCPToolInfo] { try await inner.listTools() }
    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        try await inner.callTool(name: name, arguments: arguments)
    }
    public func disconnect() async throws { try await inner.disconnect() }
}
