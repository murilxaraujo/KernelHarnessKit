import Foundation

/// Registers tools discovered from an ``MCPClient`` into a ``ToolRegistry``.
///
/// The bridge calls `tools/list` on the connected client, wraps each entry
/// in an ``AnyTool`` that forwards invocations back to the server via
/// `tools/call`, and registers the result. An optional filter can curate
/// which tools are exposed.
public struct MCPToolBridge: Sendable {
    public let client: any MCPClient

    public init(client: any MCPClient) {
        self.client = client
    }

    /// Discover tools from the MCP server and register them into `registry`.
    ///
    /// - Parameters:
    ///   - registry: Destination registry.
    ///   - filter: Optional per-tool filter. Tools where `filter` returns
    ///     `false` are skipped.
    ///   - namePrefix: Optional prefix prepended to each tool name. Useful
    ///     when bridging multiple servers that share names; the provider
    ///     sees a unique `serverA_search`, `serverB_search`.
    @discardableResult
    public func registerTools(
        into registry: ToolRegistry,
        filter: (@Sendable (MCPToolInfo) -> Bool)? = nil,
        namePrefix: String? = nil
    ) async throws -> [MCPToolInfo] {
        let tools = try await client.listTools()
        let client = self.client
        for tool in tools where filter?(tool) ?? true {
            let registeredName = namePrefix.map { "\($0)\(tool.name)" } ?? tool.name
            let info = tool
            let readOnly = info.annotations?.readOnlyHint ?? false
            let any = AnyTool(
                name: registeredName,
                description: info.description,
                inputSchema: info.inputSchema,
                execute: { arguments, _ in
                    do {
                        let result = try await client.callTool(
                            name: info.name,
                            arguments: arguments
                        )
                        return ToolResult(output: result.content, isError: result.isError)
                    } catch {
                        return .failure("MCP tool error: \(error.localizedDescription)")
                    }
                },
                isReadOnly: { _ in readOnly }
            )
            registry.register(any)
        }
        return tools
    }
}
