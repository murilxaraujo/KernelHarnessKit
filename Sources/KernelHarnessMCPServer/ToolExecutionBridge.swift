import Foundation
import KernelHarnessKit
import Logging

/// Executes a tool from the `ToolRegistry` in response to an MCP `tools/call`
/// request and maps the result into MCP's `CallToolResult` shape.
///
/// The bridge is used only when the MCP server is responsible for tool
/// execution — e.g. when a client runs its own agent loop and routes tool
/// invocations through the server. With KernelHarnessKit's standard flow the
/// local `AgentLoop` executes tools directly and this bridge is never hit;
/// `tools/list` is the only method that matters in that case.
struct ToolExecutionBridge: Sendable {
    let registry: ToolRegistry
    let contextFactory: @Sendable () -> ToolExecutionContext
    let logger: Logger

    /// Execute a tool call. Returns the MCP `CallToolResult` as a JSONValue
    /// object ready for inclusion in a JSON-RPC response.
    func call(name: String, arguments: [String: JSONValue]) async -> [String: JSONValue] {
        guard let tool = registry.get(name) else {
            logger.warning("mcp tools/call for unknown tool", metadata: ["name": .string(name)])
            return errorResult("unknown tool: \(name)")
        }

        let isReadOnly = tool.isReadOnly(rawInput: arguments)
        let context = contextFactory()
        let decision = context.permissionChecker.evaluate(
            toolName: name,
            isReadOnly: isReadOnly,
            filePath: nil,
            command: nil
        )
        guard decision.allowed else {
            let reason = decision.reason ?? "permission denied"
            return errorResult("permission denied: \(reason)")
        }

        let result = await tool.execute(rawInput: arguments, context: context)
        return [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(result.output),
                ])
            ]),
            "isError": .bool(result.isError),
        ]
    }

    private func errorResult(_ message: String) -> [String: JSONValue] {
        [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(message),
                ])
            ]),
            "isError": .bool(true),
        ]
    }
}
