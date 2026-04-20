#  ``KernelHarnessKit``

Swift infrastructure for custom AI agent harnesses — agent loop, tool system,
multi-agent coordination, deterministic workflow engine, LLM provider
abstraction, workspace, and streaming — so you define *what* your agents do
without rebuilding *how* they execute.

## Overview

KernelHarnessKit is the orchestration layer between the LLM and your domain.
It does not wrap HTTP calls to OpenAI or Anthropic; it consumes them through
a provider protocol. It is not a chat UI framework; it is headless — emit
events, build the UI yourself.

The framework makes two complementary execution strategies first-class:

- **Autonomous agents (soft harness)** — ``runAgent(context:initialMessages:)``
  runs a while-loop: the model drives, you curate the tools, the engine
  dispatches calls. Best when the LLM should make its own decisions.
- **Deterministic phase machines (hard harness)** — ``HarnessEngine`` runs a
  pre-authored sequence of phases. The system controls flow; the LLM
  executes within each constrained phase. Best when domain workflows demand
  predictable, auditable progression.

### A minimal agent

```swift
import KernelHarnessKit

let registry = ToolRegistry()
registry.registerBuiltIns()

let provider = OpenAICompatibleProvider.openai(apiKey: apiKey)
let context = QueryContext(
    provider: provider,
    toolRegistry: registry,
    permissionChecker: DefaultPermissionChecker(mode: .auto),
    workspace: InMemoryWorkspace(),
    model: "openai/gpt-4o-mini",
    systemPrompt: "You are a helpful assistant."
)

let result = runAgent(
    context: context,
    initialMessages: [ConversationMessage(role: .user, text: "list workspace files")]
)

for try await event in result.events {
    if case .textChunk(let text) = event { print(text, terminator: "") }
}
```

### A minimal harness

```swift
let phase = PhaseDefinition(
    name: "summarize",
    description: "Produce a brief summary.",
    systemPrompt: "You are a concise editor.",
    workspaceOutput: "summary.md",
    execution: .llmSingle(
        promptBuilder: { _ in "Summarize the user's request in one sentence." },
        responseFormat: nil
    )
)

let definition = HarnessDefinition(
    type: "quick_summary",
    displayName: "Quick Summary",
    description: "",
    phases: [phase]
)

let engine = HarnessEngine(
    definition: definition,
    context: HarnessContext(
        provider: provider,
        toolRegistry: registry,
        permissionChecker: DefaultPermissionChecker(mode: .auto),
        workspace: InMemoryWorkspace(),
        model: "openai/gpt-4o-mini"
    )
)

for try await event in engine.run() {
    print(event.eventType)
}
```

## Topics

### Conceptual articles

- <doc:AgentEngine>
- <doc:AuthoringTools>
- <doc:LLMProviders>
- <doc:HarnessWorkflows>
- <doc:EventStreaming>

### Tutorials

- <doc:BuildYourFirstAgent>

### The agent loop

- ``runAgent(context:initialMessages:)``
- ``AgentRunResult``
- ``QueryContext``
- ``ConversationMessage``
- ``ContentBlock``
- ``Role``
- ``AgentError``

### Tools

- ``Tool``
- ``AnyTool``
- ``ToolRegistry``
- ``ToolResult``
- ``ToolExecutionContext``
- ``WriteFileTool``
- ``ReadFileTool``
- ``EditFileTool``
- ``ListFilesTool``
- ``WriteTodosTool``
- ``ReadTodosTool``
- ``TaskTool``
- ``AskUserTool``

### Providers

- ``LLMProvider``
- ``StreamChunk``
- ``OpenAICompatibleProvider``
- ``ProviderRegistry``
- ``ResponseFormat``

### Coordination

- ``SubAgentExecutor``
- ``SubAgentConfig``
- ``BatchExecutor``
- ``BatchResult``
- ``AskUserHandler``

### Harness

- ``HarnessEngine``
- ``HarnessContext``
- ``HarnessDefinition``
- ``HarnessRegistry``
- ``HarnessPrerequisites``
- ``PhaseDefinition``
- ``PhaseExecution``
- ``PhaseContext``
- ``PhaseBatchItem``
- ``HarnessError``
- ``HarnessRun``
- ``HarnessRunStatus``

### Workspace

- ``WorkspaceProvider``
- ``WorkspaceFile``
- ``FileSource``
- ``WorkspaceError``
- ``InMemoryWorkspace``

### Streaming

- ``AgentEvent``
- ``AgentStatus``
- ``SSEEncoder``
- ``UsageSnapshot``

### Permissions

- ``PermissionChecker``
- ``PermissionDecision``
- ``PermissionMode``
- ``PermissionPolicy``
- ``PathRule``
- ``PathPermission``
- ``ToolOverride``
- ``DefaultPermissionChecker``

### Planning

- ``TodoManager``
- ``TodoItem``
- ``TodoStatus``

### MCP

- ``MCPClient``
- ``MCPToolInfo``
- ``MCPToolAnnotations``
- ``MCPToolResult``
- ``MCPError``
- ``MCPServerConfig``
- ``MCPTransport``
- ``MCPToolBridge``
- ``HTTPMCPClient``
- ``SSEMCPClient``

### Persistence protocols

- ``ThreadRepository``
- ``MessageRepository``
- ``TodoRepository``
- ``HarnessRunRepository``
- ``TokenUsageRepository``
- ``Thread``
- ``ThreadStatus``
- ``Message``
- ``TokenUsageRecord``
- ``TokenUsageSummary``

### JSON primitives

- ``JSONValue``
- ``JSONSchema``
- ``JSONValueError``
