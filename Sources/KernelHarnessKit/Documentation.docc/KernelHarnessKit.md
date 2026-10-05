#  ``KernelHarnessKit``

Swift infrastructure for custom Apple Foundation Models harnesses — native
model sessions and tool calling, multi-agent coordination, deterministic
workflow engine, workspace, permissions, persistence, and streaming.

## Overview

KernelHarnessKit uses Apple's Foundation Models session and tool abstractions
for generation. It is not a chat UI framework; it is headless — emit events,
build the UI yourself.

The framework makes two complementary execution strategies first-class:

- **Autonomous agents (soft harness)** — ``runAgent(context:initialMessages:)``
  runs a `LanguageModelSession`: Apple manages conversation history and tool
  execution while KernelHarnessKit supplies permission-aware tools.
- **Deterministic phase machines (hard harness)** — ``HarnessEngine`` runs a
  pre-authored sequence of phases. The system controls flow; the LLM
  executes within each constrained phase. Best when domain workflows demand
  predictable, auditable progression.

### A minimal agent

```swift
import KernelHarnessKit
import FoundationModels

let registry = ToolRegistry()
registry.registerBuiltIns()

let context = QueryContext(
    model: SystemLanguageModel.default,
    toolRegistry: registry,
    permissionChecker: DefaultPermissionChecker(mode: .auto),
    workspace: InMemoryWorkspace(),
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
        model: SystemLanguageModel.default,
        toolRegistry: registry,
        permissionChecker: DefaultPermissionChecker(mode: .auto),
        workspace: InMemoryWorkspace(),
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
- <doc:FoundationModelsIntegration>
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
