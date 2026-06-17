import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An MCP client that speaks streamable HTTP transport.
///
/// Sends JSON-RPC 2.0 requests via HTTP POST. Parses either a unary JSON
/// response or an SSE response whose `message` events carry JSON-RPC
/// envelopes — both are valid per the MCP specification. Suitable for
/// most HTTP-reachable MCP servers, including Anthropic's reference
/// implementations and the in-process MCP services used by Nemesis.
public final class HTTPMCPClient: MCPClient, Sendable {
    /// The server URL.
    public let url: URL

    /// Custom headers sent on every request.
    public let headers: [String: String]

    /// URLSession to use. Injectable for testing.
    public let session: URLSession

    private let state = HTTPMCPClientState()

    public init(
        url: URL,
        headers: [String: String] = [:],
        session: URLSession = .shared
    ) {
        self.url = url
        self.headers = headers
        self.session = session
    }

    public func connect() async throws {
        let params: [String: JSONValue] = [
            "protocolVersion": "2025-03-26",
            "capabilities": .object([:]),
            "clientInfo": [
                "name": "KernelHarnessKit",
                "version": .string(KHK.version),
            ],
        ]
        let response = try await call(method: "initialize", params: params)
        await state.didConnect(capabilities: response)
        // Emit the `initialized` notification per MCP spec.
        let payload = try JSONRPC.notification(method: "notifications/initialized")
        _ = try? await post(payload: payload)
    }

    public func listTools() async throws -> [MCPToolInfo] {
        let result = try await call(method: "tools/list")
        guard let list = result["tools"]?.arrayValue else {
            throw MCPError.malformedResponse("tools/list missing 'tools' array: \(result)")
        }
        return try list.map { try $0.decode(as: MCPToolInfo.self) }
    }

    public func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        let result = try await call(
            method: "tools/call",
            params: [
                "name": .string(name),
                "arguments": .object(arguments),
            ]
        )
        return Self.parseToolResult(result)
    }

    public func disconnect() async throws {
        await state.didDisconnect()
    }

    // MARK: - Transport

    /// Send a JSON-RPC request, awaiting the matching response.
    private func call(
        method: String,
        params: [String: JSONValue]? = nil
    ) async throws -> JSONValue {
        let id = await state.nextRequestID()
        let payload = try JSONRPC.request(id: id, method: method, params: params)
        let data = try await post(payload: payload)
        return try JSONRPC.parseResponse(data)
    }

    /// POST a JSON-RPC envelope and return the raw response body. Handles
    /// both JSON and SSE responses.
    private func post(payload: Data) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = payload
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw MCPError.malformedResponse("non-HTTP response: \(response)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw MCPError.http(
                status: http.statusCode,
                body: String(decoding: body, as: UTF8.self)
            )
        }

        let contentType = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if contentType.contains("text/event-stream") {
            // Walk the SSE events looking for the first JSON-RPC *response*
            // (envelope with `result` or `error`). FastMCP-based servers
            // emit `notifications/message` log entries on the same stream
            // before the response — those have a `method` field but no `id`
            // and no `result`, and must be skipped or the client misreads
            // them as a malformed response.
            let events = SSEParser.parse(body)
            for event in events {
                guard let data = event.data.data(using: .utf8) else { continue }
                if Self.isJSONRPCResponse(data) {
                    return data
                }
            }
            throw MCPError.truncatedStream
        }
        return body
    }

    /// `true` if `data` decodes as a JSON-RPC 2.0 response envelope —
    /// i.e. an object containing either `result` or `error`. Notifications
    /// (which carry `method` but no `id`) return false.
    private static func isJSONRPCResponse(_ data: Data) -> Bool {
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return false
        }
        if let result = value["result"], !result.isNull { return true }
        if let error = value["error"], !error.isNull { return true }
        return false
    }

    /// Flatten MCP content parts into a ``MCPToolResult``.
    static func parseToolResult(_ result: JSONValue) -> MCPToolResult {
        let isError = result["isError"]?.boolValue ?? false
        let parts = result["content"]?.arrayValue ?? []
        let text = parts.compactMap { part -> String? in
            guard part["type"]?.stringValue == "text" else { return nil }
            return part["text"]?.stringValue
        }.joined(separator: "\n")
        return MCPToolResult(content: text, isError: isError, rawParts: parts)
    }
}

/// Mutable HTTP MCP client state isolated behind Swift Concurrency instead of locks.
private actor HTTPMCPClientState {
    private let counter = RequestIDCounter()
    private var isConnected = false
    private var capabilities: JSONValue = .null

    func nextRequestID() async -> Int {
        await counter.next()
    }

    func didConnect(capabilities: JSONValue) {
        self.capabilities = capabilities
        isConnected = true
    }

    func didDisconnect() {
        isConnected = false
        capabilities = .null
    }
}
