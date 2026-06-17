import Foundation
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessMCPServer

@Suite("SchemaAdapter")
struct SchemaAdapterTests {
    private struct EchoTool: Tool {
        let name = "echo"
        let description = "Echo back the provided message."
        static let inputSchema = JSONSchema.object(
            properties: ["message": .string(description: "The message to echo.")],
            required: ["message"]
        )
        struct Input: Codable, Sendable { let message: String }
        func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
            .success("echoed: \(input.message)")
        }
    }

    @Test("mcpDescriptor returns name, description, and inputSchema")
    func descriptorFields() {
        let tool = AnyTool(EchoTool())
        let descriptor = SchemaAdapter.mcpDescriptor(for: tool)
        #expect(descriptor["name"] == .string("echo"))
        #expect(descriptor["description"] == .string("Echo back the provided message."))
        #expect(descriptor["inputSchema"] != nil)
        guard case .object(let schema) = descriptor["inputSchema"] else {
            Issue.record("inputSchema should be an object")
            return
        }
        #expect(schema["type"] == .string("object"))
        #expect(schema["required"] == .array([.string("message")]))
    }

    @Test("listResult wraps tools from the registry")
    func listResultWrapsTools() {
        let registry = ToolRegistry()
        registry.register(EchoTool())
        let listed = SchemaAdapter.listResult(from: registry)
        guard case .array(let tools) = listed["tools"] else {
            Issue.record("tools should be an array")
            return
        }
        #expect(tools.count == 1)
    }

    @Test("unprefix strips mcp__<server>__ prefix")
    func unprefixStripsPrefix() {
        #expect(SchemaAdapter.unprefix(toolName: "mcp__khk__echo", serverName: "khk") == "echo")
        #expect(SchemaAdapter.unprefix(toolName: "mcp__other__echo", serverName: "khk") == "mcp__other__echo")
        #expect(SchemaAdapter.unprefix(toolName: "echo", serverName: "khk") == "echo")
    }
}
