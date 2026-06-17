import Foundation
import Logging
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessMCPServer

@Suite("RPCDispatcher")
struct RPCDispatcherTests {
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

    private func makeDispatcher() -> RPCDispatcher {
        let registry = ToolRegistry()
        registry.register(EchoTool())
        let bridge = ToolExecutionBridge(
            registry: registry,
            contextFactory: {
                ToolExecutionContext(
                    workspace: InMemoryWorkspace(),
                    permissionChecker: AllowAll()
                )
            },
            logger: Logger(label: "test")
        )
        return RPCDispatcher(
            serverName: "khk",
            serverVersion: "0.1.0",
            protocolVersion: "2025-06-18",
            registry: registry,
            toolBridge: bridge,
            logger: Logger(label: "test")
        )
    }

    private func call(_ dispatcher: RPCDispatcher, method: String, id: Int, params: [String: JSONValue]? = nil) async -> JSONValue? {
        var envelope: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .integer(Int64(id)),
            "method": .string(method),
        ]
        if let params { envelope["params"] = .object(params) }
        let body = try! JSONEncoder().encode(envelope)
        let response = await dispatcher.handle(body: body)
        guard case .json(let data) = response else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    @Test("initialize returns protocol version and server info")
    func initializeHandshake() async {
        let dispatcher = makeDispatcher()
        let response = await call(dispatcher, method: "initialize", id: 0)
        #expect(response?["id"] == .integer(0))
        #expect(response?["result"]?["protocolVersion"] == .string("2025-06-18"))
        #expect(response?["result"]?["serverInfo"]?["name"] == .string("khk"))
        #expect(response?["result"]?["capabilities"]?["tools"] != nil)
    }

    @Test("tools/list returns every registered tool")
    func toolsList() async {
        let dispatcher = makeDispatcher()
        let response = await call(dispatcher, method: "tools/list", id: 1)
        guard case .array(let tools) = response?["result"]?["tools"] else {
            Issue.record("tools missing or wrong shape")
            return
        }
        #expect(tools.count == 1)
        #expect(tools.first?["name"] == .string("echo"))
    }

    @Test("tools/call executes the tool and returns output")
    func toolsCall() async {
        let dispatcher = makeDispatcher()
        let response = await call(
            dispatcher,
            method: "tools/call",
            id: 2,
            params: [
                "name": .string("echo"),
                "arguments": .object(["message": .string("hi")]),
            ]
        )
        guard case .array(let content) = response?["result"]?["content"] else {
            Issue.record("content missing")
            return
        }
        #expect(content.first?["text"] == .string("echoed: hi"))
        #expect(response?["result"]?["isError"] == .bool(false))
    }

    @Test("tools/call for unknown tool returns isError=true")
    func unknownToolIsError() async {
        let dispatcher = makeDispatcher()
        let response = await call(
            dispatcher,
            method: "tools/call",
            id: 3,
            params: [
                "name": .string("nonexistent"),
                "arguments": .object([:]),
            ]
        )
        #expect(response?["result"]?["isError"] == .bool(true))
    }

    @Test("notifications/initialized returns 202 accepted")
    func notificationsAccepted() async {
        let dispatcher = makeDispatcher()
        let body = try! JSONEncoder().encode([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
        ] as [String: String])
        let response = await dispatcher.handle(body: body)
        guard case .accepted = response else {
            Issue.record("expected .accepted, got \(response)")
            return
        }
    }

    @Test("unknown method returns JSON-RPC error -32601")
    func unknownMethodError() async {
        let dispatcher = makeDispatcher()
        let response = await call(dispatcher, method: "bogus/method", id: 4)
        #expect(response?["error"]?["code"] == .integer(-32601))
    }

    @Test("empty body returns parse error")
    func emptyBodyParseError() async {
        let dispatcher = makeDispatcher()
        let response = await dispatcher.handle(body: Data())
        guard case .json(let data) = response,
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            Issue.record("expected json response")
            return
        }
        #expect(value["error"]?["code"] == .integer(-32700))
    }
}
