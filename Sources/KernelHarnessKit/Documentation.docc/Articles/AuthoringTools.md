#  Tools

Authoring tools, registering them, and bridging MCP servers.

## Overview

Tools give the agent hands. Every capability the model can invoke — file
I/O, search, MCP calls, sub-agent delegation — is a ``Tool`` with typed
metadata, input/output schemas, permission hints, and a normalized result.

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
    static let outputSchema = JSONSchema.string(description: "Search results")
    static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

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

### Tool metadata

``AnyTool/metadata`` and ``ToolRegistry/allMetadata()`` expose the stable tool
contract: name, description, permission hints, input schema, and output schema.
Providers typically receive only the input schema through ``AnyTool/apiSchema``;
clients and registries can use the richer metadata for UI, review, and policy.

### Read-only vs. writing tools

``ToolPermissionRequirement`` is a static safety declaration. ``Tool/isReadOnly(_:)``
defaults to `false` and is evaluated per invocation — override it when an
invocation doesn't mutate external state so ``DefaultPermissionChecker`` can
run the tool under `readOnly` mode without asking.

### Input validation

Input decoding round-trips through `JSONEncoder`/`JSONDecoder`. When the
model supplies malformed arguments, ``AnyTool`` returns a
``ToolResult`` with ``ToolResult/isError`` set and a normalized ``ToolError``
(``ToolErrorKind/invalidInput``) plus a readable message. Permission denials,
unknown tools, unavailable dependencies, and execution failures use the same
structured error channel.

### Tool events and parallel execution

Every tool invocation emits ``AgentEvent/toolExecutionStarted(callId:name:input:)``
then ``AgentEvent/toolExecutionCompleted(callId:name:result:)``. Failed calls are
represented by a completed event whose result has `isError == true` and a
structured ``ToolError``.

When the model emits multiple tool calls in one turn, KernelHarnessKit starts
all calls first, dispatches them concurrently with Swift task groups, streams
completion events as each call finishes, and preserves the original model order
when appending tool results back to the conversation.

### Bridging MCP servers

Tools exposed by an MCP server are registered via ``MCPToolBridge``:

```swift
let client = HTTPMCPClient(url: URL(string: "https://api.example/mcp")!)
try await client.connect()
try await MCPToolBridge(client: client).registerTools(into: registry)
```

See <doc:Providers> for the provider abstraction the tools end up being
advertised to.
