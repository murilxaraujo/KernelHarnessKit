import Foundation

/// Metadata describing a tool exposed by an MCP server.
public struct MCPToolInfo: Sendable, Codable, Hashable {
    /// The tool name.
    public let name: String

    /// Natural-language description.
    public let description: String

    /// JSON Schema for the tool's input.
    public let inputSchema: JSONSchema

    /// Optional tool annotations (readOnly hints, destructiveness, etc.).
    public let annotations: MCPToolAnnotations?

    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        annotations: MCPToolAnnotations? = nil
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.annotations = annotations
    }
}

/// MCP tool annotations — hints about side effects.
public struct MCPToolAnnotations: Sendable, Codable, Hashable {
    /// `true` if the tool is read-only.
    public let readOnlyHint: Bool?
    /// `true` if the tool is destructive (irreversibly mutates external state).
    public let destructiveHint: Bool?
    /// `true` if calling the tool twice is equivalent to calling it once.
    public let idempotentHint: Bool?
    /// `true` if the tool talks to "open-world" systems (external APIs).
    public let openWorldHint: Bool?

    public init(
        readOnlyHint: Bool? = nil,
        destructiveHint: Bool? = nil,
        idempotentHint: Bool? = nil,
        openWorldHint: Bool? = nil
    ) {
        self.readOnlyHint = readOnlyHint
        self.destructiveHint = destructiveHint
        self.idempotentHint = idempotentHint
        self.openWorldHint = openWorldHint
    }
}

/// The normalized result of calling an MCP tool.
public struct MCPToolResult: Sendable {
    /// Flattened textual content — concatenation of every `text`-type content
    /// part in the raw response.
    public let content: String

    /// `true` if the server flagged the call as an error.
    public let isError: Bool

    /// The raw content parts as returned by the server, for consumers that
    /// need to handle non-text payloads (images, resources).
    public let rawParts: [JSONValue]

    public init(content: String, isError: Bool, rawParts: [JSONValue] = []) {
        self.content = content
        self.isError = isError
        self.rawParts = rawParts
    }
}

/// Connects to an MCP server to list and invoke tools.
public protocol MCPClient: Sendable {
    /// Handshake with the server. Safe to call multiple times.
    func connect() async throws

    /// List the tools the server exposes.
    func listTools() async throws -> [MCPToolInfo]

    /// Call a tool by name with arguments.
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult

    /// Tear down the underlying transport (if any).
    func disconnect() async throws
}

/// Errors produced by MCP client implementations.
public enum MCPError: Error, Sendable, Equatable, LocalizedError {
    /// The server returned an error envelope.
    case rpc(code: Int, message: String, data: JSONValue? = nil)
    /// The server returned a non-200 HTTP status.
    case http(status: Int, body: String)
    /// The server sent a payload that didn't match the JSON-RPC 2.0 envelope.
    case malformedResponse(String)
    /// The SSE stream ended before delivering a final JSON-RPC response.
    case truncatedStream
    /// The client was used before `connect()` succeeded.
    case notConnected

    public var errorDescription: String? {
        switch self {
        case .rpc(let code, let message, _):
            return "MCP error \(code): \(message)"
        case .http(let status, let body):
            return "MCP HTTP error \(status): \(body)"
        case .malformedResponse(let detail):
            return "Malformed MCP response: \(detail)"
        case .truncatedStream:
            return "MCP SSE stream ended without a final response."
        case .notConnected:
            return "MCP client not connected."
        }
    }
}

/// Configuration for connecting to an MCP server.
public struct MCPServerConfig: Sendable {
    /// Friendly name for logging.
    public let name: String

    /// How the client speaks to the server.
    public let transport: MCPTransport

    /// Optional per-tool filter applied at registration time.
    public let toolFilter: (@Sendable (MCPToolInfo) -> Bool)?

    public init(
        name: String,
        transport: MCPTransport,
        toolFilter: (@Sendable (MCPToolInfo) -> Bool)? = nil
    ) {
        self.name = name
        self.transport = transport
        self.toolFilter = toolFilter
    }
}

/// MCP transport variant.
public enum MCPTransport: Sendable, Hashable {
    /// Streamable HTTP (JSON responses or SSE streams on the response body).
    case streamableHTTP(url: URL, headers: [String: String] = [:])

    /// Legacy SSE — GET establishes an SSE stream, POST writes requests.
    /// Used by MCPO proxies.
    case sse(url: URL, headers: [String: String] = [:])
}
