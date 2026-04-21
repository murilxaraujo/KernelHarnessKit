import Testing
import Foundation
@testable import KernelHarnessKit

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite("MCP HTTP client", .serialized)
struct MCPHTTPClientTests {
    @Test func listsAndCallsTools() async throws {
        let url = URL(string: "https://example.test/mcp")!
        MockURLProtocol.reset()
        MockURLProtocol.register(url: url) { request in
            let body = request.httpBody ?? Data()
            let decoded = try JSONDecoder().decode(JSONValue.self, from: body)
            let method = decoded["method"]?.stringValue ?? ""
            let id = decoded["id"]?.intValue ?? 0

            switch method {
            case "initialize":
                return MockURLProtocol.jsonRPCResponse(
                    id: Int(id),
                    result: [
                        "protocolVersion": "2025-03-26",
                        "capabilities": .object([:]),
                        "serverInfo": [
                            "name": "test-server",
                            "version": "0.0.1",
                        ],
                    ]
                )
            case "tools/list":
                return MockURLProtocol.jsonRPCResponse(
                    id: Int(id),
                    result: [
                        "tools": [
                            [
                                "name": "echo",
                                "description": "Echo back the input",
                                "inputSchema": [
                                    "type": "object",
                                    "properties": ["text": ["type": "string"]],
                                    "required": ["text"],
                                ],
                                "annotations": ["readOnlyHint": true],
                            ] as JSONValue
                        ]
                    ]
                )
            case "tools/call":
                let name = decoded["params"]?["name"]?.stringValue ?? ""
                let text = decoded["params"]?["arguments"]?["text"]?.stringValue ?? ""
                return MockURLProtocol.jsonRPCResponse(
                    id: Int(id),
                    result: [
                        "content": [
                            ["type": "text", "text": .string("\(name) says: \(text)")]
                        ],
                        "isError": false,
                    ]
                )
            case "notifications/initialized":
                // Notifications don't expect a response, but provide one anyway.
                return MockURLProtocol.jsonRPCResponse(id: 0, result: .object([:]))
            default:
                return MockURLProtocol.jsonRPCResponse(
                    id: Int(id),
                    error: ["code": -32601, "message": "unknown method"]
                )
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = HTTPMCPClient(url: url, session: session)

        try await client.connect()
        let tools = try await client.listTools()
        #expect(tools.count == 1)
        #expect(tools.first?.name == "echo")
        #expect(tools.first?.annotations?.readOnlyHint == true)

        let result = try await client.callTool(name: "echo", arguments: ["text": "hello"])
        #expect(result.content == "echo says: hello")
        #expect(result.isError == false)
    }

    @Test func surfacesRPCErrors() async throws {
        let url = URL(string: "https://example.test/mcp")!
        MockURLProtocol.reset()
        MockURLProtocol.register(url: url) { _ in
            MockURLProtocol.jsonRPCResponse(
                id: 1,
                error: ["code": -32000, "message": "bad things"]
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = HTTPMCPClient(url: url, session: session)

        await #expect(throws: MCPError.rpc(code: -32000, message: "bad things")) {
            try await client.connect()
        }
    }

    @Test func skipsLogNotificationsBeforeResponse() async throws {
        // FastMCP-based servers (mcp-brasil and friends) emit
        // `notifications/message` log entries on the SSE stream before the
        // actual response. The client must walk past them.
        let url = URL(string: "https://example.test/mcp")!
        MockURLProtocol.reset()
        MockURLProtocol.registerRawSSE(url: url) { request in
            let body = request.httpBody ?? Data()
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: body)
            let id = decoded?["id"]?.intValue ?? 0
            let notification = #"{"jsonrpc":"2.0","method":"notifications/message","params":{"data":{"msg":"working"},"level":"info"}}"#
            let response = #"{"jsonrpc":"2.0","id":\#(id),"result":{"tools":[{"name":"noop","description":"noop","inputSchema":{"type":"object","properties":{}}}]}}"#
            return "event: message\ndata: \(notification)\n\nevent: message\ndata: \(response)\n\n"
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = HTTPMCPClient(url: url, session: session)

        let tools = try await client.listTools()
        #expect(tools.first?.name == "noop")
    }

    @Test func parsesSSEEnvelope() async throws {
        let url = URL(string: "https://example.test/mcp")!
        MockURLProtocol.reset()
        MockURLProtocol.registerSSE(url: url) { request in
            let body = request.httpBody ?? Data()
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: body)
            let id = decoded?["id"]?.intValue ?? 0
            let payload: JSONValue = [
                "jsonrpc": "2.0",
                "id": .integer(id),
                "result": [
                    "tools": [
                        [
                            "name": "noop",
                            "description": "noop",
                            "inputSchema": ["type": "object", "properties": .object([:])],
                        ] as JSONValue
                    ]
                ],
            ]
            return payload
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        let client = HTTPMCPClient(url: url, session: session)

        // Skip initialize by setting internal flag; just call listTools.
        let tools = try await client.listTools()
        #expect(tools.first?.name == "noop")
    }
}

@Suite("MCPToolBridge")
struct MCPToolBridgeTests {
    @Test func bridgesListedTools() async throws {
        let stub = StubMCPClient(
            tools: [
                MCPToolInfo(
                    name: "lookup",
                    description: "look up a thing",
                    inputSchema: .object(
                        properties: ["q": .string()],
                        required: ["q"]
                    )
                )
            ],
            toolResults: [
                "lookup": MCPToolResult(content: "found", isError: false)
            ]
        )
        let registry = ToolRegistry()
        let registered = try await MCPToolBridge(client: stub).registerTools(into: registry)
        #expect(registered.count == 1)
        #expect(registry.contains("lookup"))

        let context = ToolExecutionContext(
            workspace: InMemoryWorkspace(),
            permissionChecker: DefaultPermissionChecker(mode: .auto)
        )
        let result = await registry.get("lookup")!.execute(
            rawInput: ["q": "swift"],
            context: context
        )
        #expect(result.output == "found")
        #expect(result.isError == false)
    }

    @Test func appliesNamePrefix() async throws {
        let stub = StubMCPClient(
            tools: [MCPToolInfo(name: "search", description: "", inputSchema: .object(properties: [:]))],
            toolResults: ["search": MCPToolResult(content: "", isError: false)]
        )
        let registry = ToolRegistry()
        _ = try await MCPToolBridge(client: stub).registerTools(into: registry, namePrefix: "serverA_")
        #expect(registry.contains("serverA_search"))
        #expect(registry.contains("search") == false)
    }

    @Test func filtersSkippedTools() async throws {
        let stub = StubMCPClient(
            tools: [
                MCPToolInfo(name: "good", description: "", inputSchema: .object(properties: [:])),
                MCPToolInfo(name: "bad", description: "", inputSchema: .object(properties: [:])),
            ],
            toolResults: [:]
        )
        let registry = ToolRegistry()
        _ = try await MCPToolBridge(client: stub).registerTools(into: registry) { $0.name != "bad" }
        #expect(registry.contains("good"))
        #expect(registry.contains("bad") == false)
    }
}

@Suite("SSE parser")
struct SSEParserTests {
    @Test func parsesMultipleEvents() {
        let raw = """
        event: ping
        data: one

        data: two
        data: three

        """.data(using: .utf8)!
        let events = SSEParser.parse(raw)
        #expect(events.count == 2)
        #expect(events[0].name == "ping")
        #expect(events[0].data == "one")
        #expect(events[1].data == "two\nthree")
    }

    @Test func ignoresComments() {
        let raw = """
        : comment line
        data: hello

        """.data(using: .utf8)!
        let events = SSEParser.parse(raw)
        #expect(events.count == 1)
        #expect(events.first?.data == "hello")
    }
}

// MARK: - Test fixtures

final class StubMCPClient: MCPClient, @unchecked Sendable {
    let tools: [MCPToolInfo]
    let toolResults: [String: MCPToolResult]

    init(tools: [MCPToolInfo], toolResults: [String: MCPToolResult]) {
        self.tools = tools
        self.toolResults = toolResults
    }

    func connect() async throws {}
    func listTools() async throws -> [MCPToolInfo] { tools }
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult {
        toolResults[name] ?? MCPToolResult(content: "missing", isError: true)
    }
    func disconnect() async throws {}
}

/// URLProtocol stub that dispatches requests to registered handlers.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handlers: [URL: Handler] = [:]
    nonisolated(unsafe) static var sseHandlers: [URL: SSEHandler] = [:]
    nonisolated(unsafe) static var rawSSEHandlers: [URL: RawSSEHandler] = [:]

    typealias Handler = @Sendable (URLRequest) throws -> (Int, [String: String], Data)
    typealias SSEHandler = @Sendable (URLRequest) throws -> JSONValue
    typealias RawSSEHandler = @Sendable (URLRequest) throws -> String

    static func reset() {
        handlers = [:]
        sseHandlers = [:]
        rawSSEHandlers = [:]
    }

    static func register(url: URL, handler: @escaping Handler) {
        handlers[url] = handler
    }

    static func registerSSE(url: URL, handler: @escaping SSEHandler) {
        sseHandlers[url] = handler
    }

    static func registerRawSSE(url: URL, handler: @escaping RawSSEHandler) {
        rawSSEHandlers[url] = handler
    }

    static func jsonRPCResponse(
        id: Int,
        result: JSONValue? = nil,
        error: JSONValue? = nil
    ) -> (Int, [String: String], Data) {
        var envelope: [String: JSONValue] = [
            "jsonrpc": "2.0",
            "id": .integer(Int64(id)),
        ]
        if let result { envelope["result"] = result }
        if let error { envelope["error"] = error }
        let data = (try? JSONEncoder().encode(envelope)) ?? Data()
        return (200, ["Content-Type": "application/json"], data)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let url = request.url else { return false }
        return handlers[url] != nil || sseHandlers[url] != nil || rawSSEHandlers[url] != nil
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        do {
            let (status, headers, data) = try produceResponse(for: request, url: url)
            let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func produceResponse(
        for request: URLRequest,
        url: URL
    ) throws -> (Int, [String: String], Data) {
        if let handler = MockURLProtocol.handlers[url] {
            // When bodyStream is set (body > 16k buffer), rehydrate into httpBody.
            var hydrated = request
            if let stream = request.httpBodyStream, request.httpBody == nil {
                hydrated.httpBody = Data(reading: stream)
            }
            return try handler(hydrated)
        }
        if let handler = MockURLProtocol.sseHandlers[url] {
            var hydrated = request
            if let stream = request.httpBodyStream, request.httpBody == nil {
                hydrated.httpBody = Data(reading: stream)
            }
            let envelope = try handler(hydrated)
            let encoded = try JSONEncoder().encode(envelope)
            let body = "event: message\ndata: \(String(decoding: encoded, as: UTF8.self))\n\n"
            return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
        }
        if let handler = MockURLProtocol.rawSSEHandlers[url] {
            var hydrated = request
            if let stream = request.httpBodyStream, request.httpBody == nil {
                hydrated.httpBody = Data(reading: stream)
            }
            let body = try handler(hydrated)
            return (200, ["Content-Type": "text/event-stream"], Data(body.utf8))
        }
        throw URLError(.cannotFindHost)
    }
}

private extension Data {
    init(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read > 0 {
                append(buffer, count: read)
            } else {
                break
            }
        }
    }
}
