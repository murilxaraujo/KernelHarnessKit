#  Tools

Authoring tools, registering them, and bridging MCP servers.

## Overview

Tools give the agent hands. Every capability the model can invoke — file
I/O, search, MCP calls, sub-agent delegation — is a ``Tool`` with a typed
input schema, a permission check, and a normalized result.

### Authoring a tool

```swift
struct SearchTool: Tool {
    let name = "search"
    let description = "Search the knowledge base"

    struct Input: Codable, Sendable { let query: String }

    static let inputSchema = JSONSchema.object(
        properties: ["query": .string(description: "The search query")],
        required: ["query"]
    )

    func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let hits = try await retrieve(input.query)
        return .success(hits.joined(separator: "\n"))
    }

    func isReadOnly(_ input: Input) -> Bool { true }
}
```

Register into a ``ToolRegistry``:

```swift
let registry = ToolRegistry()
registry.registerBuiltIns()
registry.register(SearchTool())
```

### Built-in tools

``ToolRegistry/registerBuiltIns()`` registers the domain-agnostic tools
shipped with the framework:

- ``WriteFileTool`` · ``ReadFileTool`` · ``EditFileTool`` · ``ListFilesTool``
  — file I/O through the ``WorkspaceProvider``.
- ``WriteTodosTool`` · ``ReadTodosTool`` — planning via ``TodoManager``.
- ``TaskTool`` — delegate to a curated sub-agent.
- ``AskUserTool`` — ask the user a question and wait for their answer.

### Read-only vs. writing tools

``Tool/isReadOnly(_:)`` defaults to `false`. Override it when an invocation
doesn't mutate external state — it lets the ``DefaultPermissionChecker``
run the tool under `readOnly` mode without asking.

### Input validation

Input decoding round-trips through `JSONEncoder`/`JSONDecoder`. When the
model supplies malformed arguments, ``AnyTool`` returns a
``ToolResult`` with ``ToolResult/isError`` set and a readable message —
the agent loop surfaces it to the model so it can correct itself.

### Bridging MCP servers

Tools exposed by an MCP server are registered via ``MCPToolBridge``:

```swift
let client = HTTPMCPClient(url: URL(string: "https://api.example/mcp")!)
try await client.connect()
try await MCPToolBridge(client: client).registerTools(into: registry)
```

See <doc:Providers> for the provider abstraction the tools end up being
advertised to.
