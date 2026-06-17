import AsyncHTTPClient
import Foundation
import Logging
import NIOCore
import NIOHTTP1
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessMCPServer

@Suite("MCPServer integration")
struct MCPServerIntegrationTests {
    private struct EchoTool: Tool {
        let name = "echo"
        let description = "Echo back the provided message."
        static let inputSchema = JSONSchema.object(
            properties: ["message": .string(description: "The message.")],
            required: ["message"]
        )
        struct Input: Codable, Sendable { let message: String }
        func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
            .success("echoed: \(input.message)")
        }
        func isReadOnly(_ input: Input) -> Bool { true }
    }

    private struct AllowAll: PermissionChecker {
        func evaluate(toolName: String, isReadOnly: Bool, filePath: String?, command: String?) -> PermissionDecision {
            .allow
        }
    }

    private func startServer() async throws -> MCPServerHandle {
        let registry = ToolRegistry()
        registry.register(EchoTool())
        let server = MCPServer(
            toolRegistry: registry,
            contextFactory: {
                ToolExecutionContext(
                    workspace: InMemoryWorkspace(),
                    permissionChecker: AllowAll()
                )
            },
            logger: Logger(label: "test.mcp")
        )
        return try await server.start()
    }

    private func post(_ url: URL, body: String, client: HTTPClient) async throws -> (status: UInt, body: String) {
        var request = HTTPClientRequest(url: url.absoluteString)
        request.method = .POST
        request.headers.add(name: "content-type", value: "application/json")
        request.body = .bytes(ByteBuffer(string: body))

        let response = try await client.execute(request, timeout: .seconds(5))
        var byteBuffer = try await response.body.collect(upTo: 1024 * 1024)
        let bytes = byteBuffer.readBytes(length: byteBuffer.readableBytes) ?? []
        let text = String(decoding: bytes, as: UTF8.self)
        return (response.status.code, text)
    }

    @Test("HTTP initialize + tools/list + tools/call end to end")
    func endToEnd() async throws {
        let handle = try await startServer()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        // initialize
        let (initStatus, initBody) = try await post(
            handle.url,
            body: #"{"jsonrpc":"2.0","id":0,"method":"initialize"}"#,
            client: client
        )
        #expect(initStatus == 200)
        #expect(initBody.contains("protocolVersion"))

        // notifications/initialized
        let (notifStatus, _) = try await post(
            handle.url,
            body: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            client: client
        )
        #expect(notifStatus == 202)

        // tools/list
        let (listStatus, listBody) = try await post(
            handle.url,
            body: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#,
            client: client
        )
        #expect(listStatus == 200)
        #expect(listBody.contains(#""name":"echo""#))

        // tools/call
        let (callStatus, callBody) = try await post(
            handle.url,
            body: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"message":"hi"}}}"#,
            client: client
        )
        #expect(callStatus == 200)
        #expect(callBody.contains("echoed: hi"))

        try await client.shutdown()
        await handle.stop()
    }

    @Test("mcpConfigJSON is a valid --mcp-config payload")
    func mcpConfigShape() async throws {
        let handle = try await startServer()
        let data = handle.mcpConfigJSON.data(using: .utf8)!
        let parsed = try JSONDecoder().decode(JSONValue.self, from: data)
        let server = parsed["mcpServers"]?[handle.name]
        #expect(server?["type"] == .string("http"))
        #expect(server?["url"] == .string(handle.url.absoluteString))
        await handle.stop()
    }

    @Test("non-POST request returns 405")
    func getReturnsMethodNotAllowed() async throws {
        let handle = try await startServer()
        let client = HTTPClient(eventLoopGroupProvider: .singleton)

        var request = HTTPClientRequest(url: handle.url.absoluteString)
        request.method = .GET
        let response = try await client.execute(request, timeout: .seconds(5))
        #expect(response.status.code == 405)

        try await client.shutdown()
        await handle.stop()
    }
}
