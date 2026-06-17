import Foundation
import KernelHarnessKit

/// Converts KernelHarnessKit tool definitions to the Model Context Protocol
/// `Tool` shape that an MCP client (e.g. Claude Code) expects from a
/// `tools/list` response.
///
/// MCP's `Tool` entry is:
///
/// ```json
/// {
///   "name": "...",
///   "description": "...",
///   "inputSchema": { ...JSON Schema... }
/// }
/// ```
///
/// — which is similar to OpenAI's `function` shape minus the outer wrapper.
enum SchemaAdapter {
    /// Render a single `AnyTool` as an MCP tool descriptor.
    static func mcpDescriptor(for tool: AnyTool) -> [String: JSONValue] {
        [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema.jsonValue,
        ]
    }

    /// Render every tool in the registry as an MCP `tools/list` result body.
    static func listResult(from registry: ToolRegistry) -> [String: JSONValue] {
        let tools = registry.allTools().map(mcpDescriptor(for:))
        return ["tools": .array(tools.map(JSONValue.object))]
    }

    /// Extract the original KHK tool name from an MCP-prefixed tool name.
    ///
    /// Claude Code surfaces MCP tools as `mcp__<server-name>__<tool-name>`; when
    /// we see that form in a `ContentBlock.toolUse`, strip the prefix to recover
    /// the name registered in the `ToolRegistry`.
    static func unprefix(toolName: String, serverName: String) -> String {
        let prefix = "mcp__\(serverName)__"
        if toolName.hasPrefix(prefix) {
            return String(toolName.dropFirst(prefix.count))
        }
        return toolName
    }
}
