# KernelHarnessKit — High-Level Design

**Status:** Draft
**Date:** 2026-04-20
**Authors:** Murilo Araujo, Claude

---

## 1. Purpose

KernelHarnessKit is a Swift framework for building and deploying custom AI agent harnesses. It provides the full agentic infrastructure — agent loop, tool system, multi-agent coordination, deterministic workflow engine, LLM provider abstraction, workspace management, and streaming — so that consumers define *what* their agents do (domain prompts, tools, harnesses) without rebuilding *how* agents execute.

The first consumer is **nemesis-harness**, the "Assistente Jurídico" service for the Nemesis judicial analysis platform. The framework must be general enough to serve future clients while being concrete enough to ship Nemesis in weeks, not months.

### Design Philosophy

Adapted from two sources:

From **The AI Automators' Agentic RAG** architecture: *"The model is commoditized. Structured enforcement of process is the moat."* The framework enforces process through two complementary execution strategies — autonomous agents (soft harness) and deterministic phase machines (hard harness) — giving consumers a spectrum between LLM freedom and system control.

From **OpenHarness** (HKUDS): the insight that an agent is decomposable into a small set of orthogonal subsystems — engine, tools, permissions, hooks, coordination, memory, streaming — each with clean interfaces. OpenHarness proves this decomposition works in Python with 43+ tools and multi-agent swarms. KernelHarnessKit ports these patterns to Swift, exploiting structured concurrency (`TaskGroup`, `AsyncStream`) for the sub-agent and batch patterns that are central to the hard harness model.

### What This Is Not

KernelHarnessKit is not an LLM SDK. It does not wrap HTTP calls to OpenAI or Anthropic — it consumes them through a provider protocol. It is not a chat UI framework. It is the orchestration layer between the LLM and the domain, between user intent and tool execution.

---

## 2. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────┐
│                        Consumer Application                         │
│  (e.g., nemesis-harness — Vapor HTTP server)                        │
│                                                                     │
│  Routes, Auth, Domain Logic, Harness Definitions, System Prompts    │
└────────┬───────────────────────────────────────────────────┬────────┘
         │  uses                                             │ uses
┌────────▼────────────────────────────────────────────────────▼───────┐
│                       KernelHarnessKit                              │
│                                                                     │
│  ┌──────────┐  ┌──────────┐  ┌───────────┐  ┌──────────────────┐   │
│  │  Engine   │  │  Tools   │  │ Providers │  │    Streaming     │   │
│  │          │  │          │  │           │  │                  │   │
│  │ AgentLoop │  │ BaseTool │  │ LLMProv.  │  │ AgentEvent       │   │
│  │ QueryCtx  │  │ ToolReg. │  │ OpenAI    │  │ EventEmitter     │   │
│  │ MaxTurns  │  │ ToolExec.│  │ Anthropic │  │ SSEEncoder       │   │
│  └─────┬────┘  │ ToolRes. │  │ Google    │  └──────────────────┘   │
│        │       └─────┬────┘  └─────┬─────┘                         │
│        │             │             │                                │
│  ┌─────▼─────────────▼─────────────▼────────────────────────────┐   │
│  │                    Coordination                               │   │
│  │                                                               │   │
│  │  SubAgent    TaskGroup-based delegation                       │   │
│  │  Batch       Parallel sub-agents with concurrency control     │   │
│  │  AskUser     Pause/resume for human-in-the-loop               │   │
│  └───────────────────────────────────────────────────────────────┘   │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │   Harness    │  │  Workspace   │  │     Permissions          │   │
│  │              │  │              │  │                          │   │
│  │ PhaseEngine  │  │ WorkspacePr. │  │ PermissionChecker        │   │
│  │ PhaseTypes   │  │ InMemory     │  │ PermissionMode           │   │
│  │ HarnessDef.  │  │ PostgreSQL   │  │ PathRule, CmdRule         │   │
│  │ Registry     │  │ FileSystem   │  │ ToolGating               │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
│                                                                     │
│  ┌──────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │    Hooks     │  │     MCP      │  │      Persistence         │   │
│  │              │  │              │  │                          │   │
│  │ HookEvent    │  │ MCPClient    │  │ ThreadRepo (protocol)    │   │
│  │ HookExecutor │  │ MCPToolBrdg. │  │ MessageRepo (protocol)   │   │
│  │ PreToolUse   │  │ MCPConfig    │  │ WorkspaceRepo (protocol) │   │
│  │ PostToolUse  │  │              │  │ HarnessRunRepo (proto.)  │   │
│  └──────────────┘  └──────────────┘  └──────────────────────────┘   │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │                    Planning (Todos)                           │   │
│  │                                                               │   │
│  │  TodoList    In-memory plan state, exposed as tool + events   │   │
│  │  TodoRepo    Protocol for persistent backing                  │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 3. Subsystem Specifications

### 3.1 Engine — The Agent Loop

The engine is the heartbeat: a `while` loop that calls the LLM, dispatches tool calls, appends results, and repeats until the model stops requesting tools or a turn limit is reached.

**Inspiration from OpenHarness:** The `run_query()` function in OpenHarness implements exactly this pattern — streaming from the API, handling `ApiTextDeltaEvent` / `ApiMessageCompleteEvent`, executing tools (single sequential, multiple concurrent via `asyncio.gather`), and looping. KernelHarnessKit ports this to Swift `AsyncThrowingStream` and `TaskGroup`.

#### Core Types

```swift
/// Shared context for a single query run.
public struct QueryContext: Sendable {
    public let provider: any LLMProvider
    public let toolRegistry: ToolRegistry
    public let permissionChecker: PermissionChecker
    public let workspace: any WorkspaceProvider
    public let model: String
    public let systemPrompt: String
    public let maxTokens: Int
    public let maxTurns: Int                        // default 200 (matches OpenHarness)
    public let hookExecutor: HookExecutor?
    public let askUserHandler: AskUserHandler?      // pause/resume callback
    public let contextWindowTokens: Int?
    public let toolMetadata: ToolMetadata            // carryover state across turns
}

/// A single message in conversation history.
public struct ConversationMessage: Codable, Sendable {
    public let role: Role                           // .system, .user, .assistant, .tool
    public let content: [ContentBlock]              // text, image, toolUse, toolResult
}

/// Content block discriminated union (matches OpenHarness pattern).
public enum ContentBlock: Codable, Sendable {
    case text(String)
    case image(data: Data, mediaType: String)
    case toolUse(id: String, name: String, input: [String: JSONValue])
    case toolResult(toolUseId: String, content: String, isError: Bool)
}
```

#### Agent Loop

```swift
/// Run the agent loop. Yields streaming events as an AsyncThrowingStream.
public func runQuery(
    context: QueryContext,
    messages: inout [ConversationMessage]
) -> AsyncThrowingStream<(AgentEvent, UsageSnapshot?), Error> {
    AsyncThrowingStream { continuation in
        Task {
            var turnCount = 0
            while context.maxTurns == nil || turnCount < context.maxTurns {
                turnCount += 1

                // 1. Stream from LLM
                let stream = context.provider.streamChat(
                    model: context.model,
                    messages: messages,
                    systemPrompt: context.systemPrompt,
                    tools: context.toolRegistry.toAPISchema(),
                    maxTokens: context.maxTokens
                )

                var finalMessage: ConversationMessage?
                var usage: UsageSnapshot?

                for try await chunk in stream {
                    switch chunk {
                    case .textDelta(let text):
                        continuation.yield((.textChunk(text), nil))
                    case .messageComplete(let message, let u):
                        finalMessage = message
                        usage = u
                    case .retry(let attempt, let delay, let reason):
                        continuation.yield((.status("Retrying in \(delay)s: \(reason)"), nil))
                    }
                }

                guard let assistantMessage = finalMessage else {
                    throw AgentError.noFinalMessage
                }

                messages.append(assistantMessage)
                continuation.yield((.turnComplete(assistantMessage, usage), usage))

                // 2. Extract tool calls
                let toolCalls = assistantMessage.toolUses
                guard !toolCalls.isEmpty else {
                    // No tools requested — agent is done
                    continuation.finish()
                    return
                }

                // 3. Execute tools (single: sequential, multiple: concurrent)
                let results: [ContentBlock]
                if toolCalls.count == 1 {
                    let tc = toolCalls[0]
                    continuation.yield((.toolExecutionStarted(tc.name, tc.input), nil))
                    let result = try await executeToolCall(context: context, call: tc)
                    continuation.yield((.toolExecutionCompleted(tc.name, result), nil))
                    results = [.toolResult(
                        toolUseId: tc.id, content: result.output, isError: result.isError
                    )]
                } else {
                    // Concurrent execution via TaskGroup
                    for tc in toolCalls {
                        continuation.yield((.toolExecutionStarted(tc.name, tc.input), nil))
                    }
                    results = try await withThrowingTaskGroup(of: (Int, ToolResult).self) { group in
                        for (i, tc) in toolCalls.enumerated() {
                            group.addTask {
                                let r = try await executeToolCall(context: context, call: tc)
                                return (i, r)
                            }
                        }
                        var ordered = Array<ToolResult?>(repeating: nil, count: toolCalls.count)
                        for try await (i, result) in group {
                            ordered[i] = result
                        }
                        return zip(toolCalls, ordered).map { tc, r in
                            let result = r ?? ToolResult(output: "Tool execution failed", isError: true)
                            continuation.yield((.toolExecutionCompleted(tc.name, result), nil))
                            return .toolResult(
                                toolUseId: tc.id, content: result.output, isError: result.isError
                            )
                        }
                    }
                }

                // 4. Append tool results and loop
                messages.append(ConversationMessage(role: .user, content: results))
            }

            throw AgentError.maxTurnsExceeded(context.maxTurns)
        }
    }
}
```

**Key design decisions:**

- **Single vs. concurrent tool execution** mirrors OpenHarness: one tool runs sequentially for simpler event ordering; multiple tools run via `TaskGroup` to avoid leaving unanswered tool_use blocks (the Anthropic API rejects the next request if any tool_use lacks a matching tool_result).
- **Turn counting** with configurable `maxTurns` (default 200) prevents runaway loops.
- **Reactive compaction** (context too long) can be added as a middleware concern — the engine emits a `contextTooLong` event and the consumer decides whether to compact or abort.

### 3.2 Tools — The Capability Layer

Tools give the agent hands. Every capability — file I/O, search, MCP calls, sub-agent delegation — is a tool with a typed schema, permission check, and hook integration.

**Inspiration from OpenHarness:** `BaseTool` is an abstract class with `name`, `description`, `input_model` (Pydantic), `execute()`, `is_read_only()`, and `to_api_schema()`. The `ToolRegistry` maps names to implementations. KernelHarnessKit mirrors this with Swift protocols and `Codable` replacing Pydantic.

#### Core Protocols

```swift
/// Every tool conforms to this protocol.
public protocol Tool: Sendable {
    /// Unique tool name (e.g., "write_file", "semantic_search_decisions").
    var name: String { get }

    /// Human-readable description for the LLM.
    var description: String { get }

    /// The Codable type that validates and parses tool input.
    associatedtype Input: Codable & Sendable

    /// Execute the tool with validated input.
    func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult

    /// Whether this invocation is read-only (affects permission gating).
    func isReadOnly(_ input: Input) -> Bool

    /// JSON Schema for the input type (auto-generated from Codable via reflection or macro).
    static var inputSchema: JSONSchema { get }
}

/// Default implementation: tools are write by default.
extension Tool {
    public func isReadOnly(_ input: Input) -> Bool { false }
}

/// Normalized tool result.
public struct ToolResult: Sendable {
    public let output: String
    public let isError: Bool
    public let metadata: [String: JSONValue]

    public init(output: String, isError: Bool = false, metadata: [String: JSONValue] = [:]) {
        self.output = output
        self.isError = isError
        self.metadata = metadata
    }
}

/// Context passed to every tool execution.
public struct ToolExecutionContext: Sendable {
    public let workspace: any WorkspaceProvider
    public let metadata: ToolMetadata
    public let hookExecutor: HookExecutor?
}
```

#### Tool Registry

```swift
/// Type-erased tool wrapper for heterogeneous storage.
public struct AnyTool: Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONSchema
    private let _execute: @Sendable ([String: JSONValue], ToolExecutionContext) async throws -> ToolResult
    private let _isReadOnly: @Sendable ([String: JSONValue]) -> Bool

    public func execute(rawInput: [String: JSONValue], context: ToolExecutionContext) async throws -> ToolResult {
        try await _execute(rawInput, context)
    }

    public func isReadOnly(rawInput: [String: JSONValue]) -> Bool {
        _isReadOnly(rawInput)
    }

    public func toAPISchema() -> [String: Any] {
        ["name": name, "description": description, "input_schema": inputSchema.dictionary]
    }
}

/// Registry mapping tool names to implementations.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: AnyTool] = [:]

    public func register<T: Tool>(_ tool: T) { ... }
    public func get(_ name: String) -> AnyTool? { tools[name] }
    public func allTools() -> [AnyTool] { Array(tools.values) }
    public func toAPISchema() -> [[String: Any]] { tools.values.map { $0.toAPISchema() } }

    /// Return a filtered registry (used by harness phases for tool curation).
    public func filtered(allowing names: Set<String>) -> ToolRegistry { ... }
    public func filtered(excluding names: Set<String>) -> ToolRegistry { ... }
}
```

#### Built-in Tools

The framework ships with domain-agnostic tools that any consumer needs:

| Tool | Purpose | Category |
|------|---------|----------|
| `write_file` | Create/overwrite workspace file | Workspace |
| `read_file` | Read workspace file content | Workspace |
| `edit_file` | Exact string replacement in workspace file | Workspace |
| `list_files` | Enumerate workspace contents | Workspace |
| `write_todos` | Replace full todo list (agent planning) | Planning |
| `read_todos` | Read current plan | Planning |
| `task` | Delegate to sub-agent with isolated context | Coordination |
| `ask_user` | Pause for user clarification | Coordination |

Consumers register additional tools — domain-specific (Nemesis search tools) or from MCP servers.

#### MCP Tool Bridge

MCP tools discovered from connected servers are automatically wrapped as `AnyTool` instances and registered:

```swift
/// Bridges MCP server tools into the ToolRegistry.
public struct MCPToolBridge {
    let client: MCPClient

    /// Discover tools from the MCP server and register them.
    public func registerTools(into registry: ToolRegistry, filter: ((MCPToolInfo) -> Bool)? = nil) async throws {
        let serverTools = try await client.listTools()
        for tool in serverTools where filter?(tool) ?? true {
            registry.register(MCPProxyTool(client: client, info: tool))
        }
    }
}

/// Wraps a single MCP server tool as an AnyTool for the ToolRegistry.
/// Handles input validation, JSON-RPC invocation, and result normalization.
public struct MCPProxyTool: Sendable {
    let client: MCPClient
    let info: MCPToolInfo       // name, description, inputSchema from tools/list

    var name: String { info.name }
    var description: String { info.description }
    var inputSchema: JSONSchema { info.inputSchema }

    func execute(rawInput: [String: JSONValue], context: ToolExecutionContext) async throws -> ToolResult {
        let mcpResult = try await client.callTool(name: info.name, arguments: rawInput)
        return ToolResult(output: mcpResult.content, isError: mcpResult.isError)
    }

    func isReadOnly(rawInput: [String: JSONValue]) -> Bool {
        // MCP tools are conservatively treated as write operations
        // unless the server annotates them as read-only
        info.annotations?.readOnly ?? false
    }
}
```

### 3.3 LLM Providers — The Model Layer

The provider abstraction decouples the engine from any specific LLM vendor.

**Inspiration from OpenHarness:** `SupportsStreamingMessages` is a Protocol with a single method `stream_message() -> AsyncIterator[ApiStreamEvent]`. Three event types: `ApiTextDeltaEvent`, `ApiMessageCompleteEvent`, `ApiRetryEvent`. Clean, minimal. KernelHarnessKit mirrors this exactly.

```swift
/// Protocol that any LLM provider must satisfy.
public protocol LLMProvider: Sendable {
    func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error>
}

/// Events produced by the provider stream.
public enum StreamChunk: Sendable {
    case textDelta(String)
    case messageComplete(ConversationMessage, UsageSnapshot)
    case retry(attempt: Int, delay: TimeInterval, reason: String)
}

/// Token usage snapshot.
public struct UsageSnapshot: Sendable {
    public var promptTokens: Int = 0
    public var completionTokens: Int = 0
    public var totalTokens: Int { promptTokens + completionTokens }
}
```

**Shipped providers:**

| Provider | SDK | Notes |
|----------|-----|-------|
| `OpenAIProvider` | MacPaw/OpenAI | Primary, best tool-calling support |
| `AnthropicProvider` | AsyncHTTPClient + Messages API | Native tool_use blocks, no vendor SDK needed |
| `GoogleProvider` | AsyncHTTPClient + Gemini API | Function calling, no vendor SDK needed |

**Runtime selection:**

```swift
public struct ProviderRegistry: Sendable {
    private let providers: [String: any LLMProvider]

    public func provider(for modelId: String) -> any LLMProvider {
        // modelId format: "openai/gpt-4o", "anthropic/claude-sonnet-4-20250514"
        let prefix = modelId.prefix(while: { $0 != "/" })
        return providers[String(prefix)] ?? providers["openai"]!
    }
}
```

### 3.4 Streaming — The Event Layer

All agent activity is surfaced as a typed event stream. The consumer (typically an HTTP handler) encodes these into SSE, WebSocket frames, or any transport.

**Inspiration from OpenHarness:** Seven frozen dataclass event types forming a `StreamEvent` union. KernelHarnessKit adopts the same pattern as a Swift enum with associated values.

```swift
/// Every event the engine or harness can emit.
public enum AgentEvent: Sendable {
    // --- Engine events ---
    case textChunk(String)
    case turnComplete(ConversationMessage, UsageSnapshot?)
    case toolExecutionStarted(String, [String: JSONValue])
    case toolExecutionCompleted(String, ToolResult)
    case status(String)
    case error(AgentError)

    // --- Agent coordination ---
    case statusChange(AgentStatus)                  // working, waitingForUser, complete, error
    case todosUpdated([TodoItem])
    case subAgentStarted(id: String, description: String)
    case subAgentCompleted(id: String, summary: String)

    // --- Harness events ---
    case harnessPhaseStart(name: String, index: Int, total: Int)
    case harnessPhaseComplete(name: String, summary: String)
    case harnessPhaseError(name: String, error: String)
    case harnessComplete
    case harnessBatchStart(itemCount: Int)
    case harnessBatchProgress(current: Int, total: Int)
    case harnessHumanInput(question: String)
}

/// Agent status state machine.
public enum AgentStatus: String, Codable, Sendable {
    case idle
    case working
    case waitingForUser
    case complete
    case error
    case cancelled
}
```

**SSE Encoding** is a thin utility, not a framework opinion:

```swift
/// Encode AgentEvent as an SSE line. Consumer mounts this into their HTTP framework.
public struct SSEEncoder {
    public static func encode(_ event: AgentEvent) -> String {
        let type = event.eventType     // e.g., "agent_text_chunk", "harness_phase_start"
        let data = event.jsonPayload   // JSON-encoded associated values
        return "event: \(type)\ndata: \(data)\n\n"
    }
}

extension AgentEvent {
    /// SSE event type string.
    public var eventType: String {
        switch self {
        case .textChunk:              return "agent_text_chunk"
        case .turnComplete:           return "agent_turn_complete"
        case .toolExecutionStarted:   return "agent_tool_call_start"
        case .toolExecutionCompleted: return "agent_tool_call_result"
        case .status:                 return "agent_status"
        case .error:                  return "agent_error"
        case .statusChange:           return "agent_status_change"
        case .todosUpdated:           return "agent_todos_updated"
        case .subAgentStarted:        return "agent_sub_agent_start"
        case .subAgentCompleted:      return "agent_sub_agent_complete"
        case .harnessPhaseStart:      return "harness_phase_start"
        case .harnessPhaseComplete:   return "harness_phase_complete"
        case .harnessPhaseError:      return "harness_phase_error"
        case .harnessComplete:        return "harness_complete"
        case .harnessBatchStart:      return "harness_batch_start"
        case .harnessBatchProgress:   return "harness_batch_progress"
        case .harnessHumanInput:      return "harness_human_input"
        }
    }

    /// JSON-encoded payload of associated values.
    public var jsonPayload: String {
        // Implementation uses JSONEncoder on a Codable mirror of each case's data.
        // Omitted for brevity — each case maps its associated values to a flat dictionary.
    }
}
```

### 3.5 Coordination — Sub-Agents and Delegation

The coordination layer enables an agent to spawn isolated sub-agents for parallel work.

**Inspiration from OpenHarness:** The coordinator/swarm split. The coordinator uses `agent`, `send_message`, `task_stop` tools to manage workers. Workers run as subprocesses with isolated memory but shared filesystem. In KernelHarnessKit, sub-agents run as `TaskGroup` children (in-process, structured concurrency) rather than subprocesses — simpler, lower overhead, better suited for the batch-analysis pattern central to hard harnesses.

```swift
/// Execute a sub-agent with isolated conversation history but shared workspace.
public struct SubAgentExecutor: Sendable {
    public let workspace: any WorkspaceProvider    // shared with parent
    public let toolRegistry: ToolRegistry          // curated (no task, no todos)
    public let provider: any LLMProvider
    public let maxTurns: Int                       // default 15

    public func run(
        systemPrompt: String,
        initialMessage: String,
        model: String,
        eventHandler: (@Sendable (AgentEvent) async -> Void)? = nil
    ) async throws -> String {
        // Runs a full agent loop with isolated messages.
        // Returns the last assistant text as the result.
    }
}

/// Batch execution: run N sub-agents concurrently with controlled parallelism.
public struct BatchExecutor: Sendable {
    public let concurrency: Int                    // default 5
    public let subAgentConfig: SubAgentConfig

    public func execute<Item: Sendable>(
        items: [Item],
        promptBuilder: @Sendable (Item) -> String,
        eventEmitter: (@Sendable (AgentEvent) async -> Void)? = nil
    ) async throws -> [BatchResult<Item>] {
        try await withThrowingTaskGroup(of: BatchResult<Item>.self) { group in
            var results: [BatchResult<Item>] = []
            var active = 0

            for (index, item) in items.enumerated() {
                // Throttle: wait for a slot if at concurrency limit
                while active >= concurrency {
                    if let result = try await group.next() {
                        results.append(result)
                        active -= 1
                    }
                }

                active += 1
                await eventEmitter?(.harnessBatchProgress(current: index + 1, total: items.count))

                group.addTask {
                    let executor = SubAgentExecutor(/* config */)
                    let output = try await executor.run(
                        systemPrompt: subAgentConfig.systemPrompt,
                        initialMessage: promptBuilder(item),
                        model: subAgentConfig.model
                    )
                    return BatchResult(item: item, output: output, index: index)
                }
            }

            // Drain remaining
            for try await result in group {
                results.append(result)
            }

            return results.sorted(by: { $0.index < $1.index })
        }
    }
}
```

**Ask-User flow** (human-in-the-loop):

```swift
/// Handler that the consumer provides to bridge ask_user to their transport.
public protocol AskUserHandler: Sendable {
    /// Called when the agent needs user input. Suspends until the user responds.
    func askUser(question: String) async throws -> String
}
```

When the `ask_user` tool is called, the engine invokes this handler, which typically emits a `harnessHumanInput` SSE event and suspends via a `CheckedContinuation` until the consumer calls a resume endpoint.

### 3.6 Harness Engine — Deterministic Workflows

The harness engine is the "hard harness" — a phase state machine where the system controls flow and the LLM executes within constrained phases.

**This is the differentiator.** OpenHarness provides the agent loop and coordination but does not have a concept of deterministic phase machines. The harness engine is original to KernelHarnessKit, designed from the Nemesis ADR's requirements.

#### Phase Types

```swift
/// How a phase executes.
public enum PhaseType: Sendable {
    /// Pure Swift code, no LLM. Data extraction, parsing, transformation.
    case programmatic

    /// Single LLM call with structured JSON output validated against a Codable schema.
    case llmSingle

    /// Multi-round agent loop with curated tool access (scoped deep mode).
    case llmAgent

    /// Spawns isolated sub-agents per item with configurable concurrency.
    case llmBatchAgents(concurrency: Int = 5)

    /// Pauses harness, generates context-aware questions, waits for user.
    case llmHumanInput
}
```

#### Phase Definition

```swift
/// A single phase in a harness workflow.
public struct PhaseDefinition<Output: Codable & Sendable>: Sendable {
    public let name: String
    public let description: String
    public let phaseType: PhaseType
    public let systemPromptTemplate: String           // focused 5-15 lines
    public let tools: Set<String>                     // curated tool names for this phase
    public let outputSchema: Output.Type?             // for structured validation
    public let workspaceInputs: [String]              // files this phase reads
    public let workspaceOutput: String                // file this phase writes
    public let timeout: Duration                      // per-phase timeout
    public let postExecute: (@Sendable (Output, any WorkspaceProvider) async throws -> Void)?
}
```

#### Harness Definition

```swift
/// A complete harness workflow — a named sequence of phases.
public struct HarnessDefinition: Sendable {
    public let type: String                           // e.g., "case_research"
    public let displayName: String
    public let description: String
    public let prerequisites: HarnessPrerequisites    // required uploads, intro text
    public let phases: [AnyPhaseDefinition]           // type-erased phase sequence
}

/// Registry of available harnesses.
public final class HarnessRegistry: @unchecked Sendable {
    private var definitions: [String: HarnessDefinition] = [:]

    public func register(_ definition: HarnessDefinition) { ... }
    public func get(_ type: String) -> HarnessDefinition? { ... }
    public func allDefinitions() -> [HarnessDefinition] { ... }
}
```

#### Harness Engine Execution

```swift
/// Executes a harness definition as a phase state machine.
public actor HarnessEngine {
    private let definition: HarnessDefinition
    private let context: HarnessContext               // provider, tools, workspace, etc.
    private var currentPhase: Int = 0
    private var status: HarnessRunStatus = .pending
    private var phaseResults: [String: Data] = [:]    // phase name → structured output

    /// Run the harness. Yields events as phases progress.
    public func run() -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                status = .running

                // Gatekeeper LLM: validate prerequisites, greet user
                try await runGatekeeper(continuation: continuation)

                // Phase loop
                for (index, phase) in definition.phases.enumerated() {
                    currentPhase = index
                    continuation.yield(.harnessPhaseStart(
                        name: phase.name, index: index, total: definition.phases.count
                    ))

                    do {
                        try await executePhase(phase, continuation: continuation)
                        continuation.yield(.harnessPhaseComplete(
                            name: phase.name, summary: "Phase completed"
                        ))
                    } catch is CancellationError {
                        status = .cancelled
                        throw CancellationError()
                    } catch {
                        continuation.yield(.harnessPhaseError(
                            name: phase.name, error: error.localizedDescription
                        ))
                        status = .failed
                        throw error
                    }
                }

                // Post-harness LLM: conversational summary
                try await runPostHarness(continuation: continuation)

                status = .completed
                continuation.yield(.harnessComplete)
                continuation.finish()
            }
        }
    }

    private func executePhase(_ phase: AnyPhaseDefinition, continuation: ...) async throws {
        switch phase.phaseType {
        case .programmatic:
            // Direct Swift execution, no LLM
            try await phase.executeProgrammatic(workspace: context.workspace)

        case .llmSingle:
            // Single LLM call with structured output
            let curatedTools = context.toolRegistry.filtered(allowing: phase.tools)
            let result = try await singleLLMCall(
                systemPrompt: phase.systemPromptTemplate,
                tools: curatedTools,
                outputSchema: phase.outputSchema
            )
            // Validate and write to workspace
            try await context.workspace.writeFile(
                path: phase.workspaceOutput,
                content: result
            )

        case .llmAgent:
            // Multi-round agent loop (mini deep mode)
            let curatedTools = context.toolRegistry.filtered(allowing: phase.tools)
            let agentLoop = SubAgentExecutor(
                workspace: context.workspace,
                toolRegistry: curatedTools,
                provider: context.provider,
                maxTurns: 25
            )
            let result = try await agentLoop.run(
                systemPrompt: phase.systemPromptTemplate,
                initialMessage: buildPhasePrompt(phase),
                model: context.model
            )
            try await context.workspace.writeFile(path: phase.workspaceOutput, content: result)

        case .llmBatchAgents(let concurrency):
            // Parallel sub-agents via BatchExecutor
            let items = try await loadBatchItems(for: phase)
            continuation.yield(.harnessBatchStart(itemCount: items.count))
            let batch = BatchExecutor(
                concurrency: concurrency,
                subAgentConfig: buildSubAgentConfig(phase)
            )
            let results = try await batch.execute(items: items, promptBuilder: phase.batchPromptBuilder)
            let merged = mergeResults(results)
            try await context.workspace.writeFile(path: phase.workspaceOutput, content: merged)

        case .llmHumanInput:
            // Pause for user input
            status = .paused
            let question = try await generateQuestion(phase)
            continuation.yield(.harnessHumanInput(question: question))
            let response = try await context.askUserHandler.askUser(question: question)
            status = .running
            try await context.workspace.writeFile(
                path: phase.workspaceOutput,
                content: response
            )
        }
    }
}
```

**Key design properties:**

- **Thin orchestrator** — the engine itself is ~5k tokens of system overhead regardless of task scope. Domain context lives in workspace files, not inline.
- **Curated tools per phase** — each phase gets only the tools it needs. A clause-analysis sub-agent gets a focused prompt and RAG tool, not a 400-line omnibus.
- **Workspace-based context passing** — phases read/write files, enabling resumability. If interrupted mid-batch, the engine detects partial output and resumes from where it left off.
- **Timeout enforcement** — each phase has a `Duration` timeout via Swift's `Task.sleep(for:)` with cancellation.

### 3.7 Workspace — The Virtual Filesystem

The workspace provides a per-session virtual filesystem where agents read, write, and edit files. It's the medium through which harness phases pass context and through which agents produce deliverables.

```swift
/// Protocol for workspace storage. Consumer provides the implementation.
public protocol WorkspaceProvider: Sendable {
    func readFile(path: String) async throws -> String
    func writeFile(path: String, content: String) async throws
    func editFile(path: String, oldString: String, newString: String) async throws
    func listFiles() async throws -> [WorkspaceFile]
    func deleteFile(path: String) async throws
    func fileExists(path: String) async throws -> Bool
}

public struct WorkspaceFile: Codable, Sendable {
    public let path: String
    public let sizeBytes: Int64
    public let source: FileSource                    // .agent, .harness, .upload
    public let updatedAt: Date
}

public enum FileSource: String, Codable, Sendable {
    case agent, harness, upload
}
```

**Shipped implementations:**

| Implementation | Backing | Use Case |
|----------------|---------|----------|
| `InMemoryWorkspace` | Dictionary | Testing, ephemeral sessions |
| `PostgresWorkspace` | `workspace_files` table | Production (Nemesis pattern) |
| `FileSystemWorkspace` | Local disk | CLI tools, local development |

### 3.8 Permissions — Safety Boundaries

**Inspiration from OpenHarness:** Three modes (Default: ask before writes, Auto: allow everything, Plan: block all writes), plus path-level rules and command denial lists. The `PermissionChecker.evaluate()` returns a decision with `allowed`, `requires_confirmation`, and `reason`.

```swift
/// Permission evaluation result.
public struct PermissionDecision: Sendable {
    public let allowed: Bool
    public let requiresConfirmation: Bool
    public let reason: String?
}

/// Permission mode (consumer-configurable).
public enum PermissionMode: Sendable {
    case `default`       // ask before writes
    case auto            // allow everything
    case readOnly        // block all writes
    case custom(PermissionPolicy)
}

/// Custom permission rules for fine-grained control.
public struct PermissionPolicy: Sendable {
    public let pathRules: [PathRule]         // allow/deny by file path pattern
    public let commandDenyList: [String]     // blocked shell commands
    public let toolOverrides: [String: Bool] // tool name → always allow/deny
}

public struct PathRule: Sendable {
    public let pattern: String              // glob pattern (e.g., "/tmp/**")
    public let permission: PathPermission   // .allow, .deny, .askUser
}

public enum PathPermission: Sendable {
    case allow, deny, askUser
}

/// Evaluates whether a tool invocation is permitted.
public protocol PermissionChecker: Sendable {
    func evaluate(
        toolName: String,
        isReadOnly: Bool,
        filePath: String?,
        command: String?
    ) -> PermissionDecision
}
```

### 3.9 Hooks — Lifecycle Events

**Inspiration from OpenHarness:** `PreToolUse` and `PostToolUse` hooks with a `HookExecutor` that runs registered handlers. Hooks can block tool execution (pre) or observe results (post).

```swift
public enum HookEvent: String, Sendable {
    case preToolUse
    case postToolUse
    case stop
    case notification
}

public protocol HookHandler: Sendable {
    func handle(event: HookEvent, payload: [String: Any]) async -> HookResult
}

public struct HookResult: Sendable {
    public let blocked: Bool
    public let reason: String?
}

public actor HookExecutor {
    private var handlers: [HookEvent: [any HookHandler]] = [:]

    public func register(_ handler: any HookHandler, for event: HookEvent) { ... }
    public func execute(_ event: HookEvent, payload: [String: Any]) async -> HookResult { ... }
}
```

### 3.10 MCP Client — Tool Server Integration

Connects to external MCP servers to discover and invoke tools.

```swift
/// MCP client that connects to a tool server.
public protocol MCPClient: Sendable {
    func connect() async throws
    func listTools() async throws -> [MCPToolInfo]
    func callTool(name: String, arguments: [String: JSONValue]) async throws -> MCPToolResult
    func disconnect() async throws
}

/// Configuration for an MCP server connection.
public struct MCPServerConfig: Codable, Sendable {
    public let name: String
    public let transport: MCPTransport
    public let toolFilter: MCPToolFilter?            // optional category/name filter
}

public enum MCPTransport: Codable, Sendable {
    case streamableHTTP(url: URL)                    // JSON-RPC over HTTP
    case sse(url: URL)                               // Server-Sent Events (MCPO)
    case stdio(command: String, args: [String])      // Subprocess
}
```

**Shipped implementations:**

| Transport | Class | Use Case |
|-----------|-------|----------|
| Streamable HTTP | `HTTPMCPClient` | Internal services (nemesis-api MCP) |
| SSE | `SSEMCPClient` | MCPO proxies (mcp-brasil) |
| Stdio | `StdioMCPClient` | Local MCP servers |

### 3.11 Persistence — Repository Protocols

The framework defines repository protocols for all stateful entities. Consumers provide implementations backed by their database of choice.

```swift
public protocol ThreadRepository: Sendable {
    func create(_ thread: Thread) async throws -> Thread
    func get(id: UUID) async throws -> Thread?
    func list(userId: String, status: ThreadStatus?) async throws -> [Thread]
    func update(_ thread: Thread) async throws
    func delete(id: UUID) async throws
}

public protocol MessageRepository: Sendable {
    func append(_ message: Message, threadId: UUID) async throws
    func list(threadId: UUID) async throws -> [Message]
    func deleteAll(threadId: UUID) async throws
}

public protocol TodoRepository: Sendable {
    func get(threadId: UUID) async throws -> [TodoItem]
    func replace(threadId: UUID, items: [TodoItem]) async throws
}

public protocol HarnessRunRepository: Sendable {
    func create(_ run: HarnessRun) async throws -> HarnessRun
    func get(id: UUID) async throws -> HarnessRun?
    func update(_ run: HarnessRun) async throws
    func activeRun(threadId: UUID) async throws -> HarnessRun?
}

public protocol TokenUsageRepository: Sendable {
    func record(_ usage: TokenUsageRecord) async throws
    func summary(userId: String, since: Date) async throws -> TokenUsageSummary
}
```

**The framework ships with PostgresNIO implementations as an optional target** (`KernelHarnessPostgres`), since PostgreSQL is the common case. Consumers who need DynamoDB, SQLite, or in-memory can implement the protocols directly.

### 3.12 Planning — Todo System

The todo system gives the agent a visible planning surface. Inspired by both OpenHarness's `todo_write` tool and the Nemesis ADR's plan panel.

```swift
/// In-memory todo state, backed by a repository for persistence.
public actor TodoManager {
    private var items: [TodoItem] = []
    private let repository: (any TodoRepository)?
    private let threadId: UUID

    public func replace(_ newItems: [TodoItem]) async throws {
        items = newItems
        try await repository?.replace(threadId: threadId, items: items)
    }

    public func current() -> [TodoItem] { items }
}

public struct TodoItem: Codable, Sendable {
    public let content: String
    public let status: TodoStatus
}

public enum TodoStatus: String, Codable, Sendable {
    case pending, inProgress, completed
}
```

Exposed to the agent via `write_todos` and `read_todos` tools. Changes emit `todosUpdated` events for real-time UI updates.

---

## 4. Swift Package Structure

```
KernelHarnessKit/
├── Package.swift
├── Sources/
│   ├── KernelHarnessKit/                      # Core framework
│   │   ├── Engine/
│   │   │   ├── AgentLoop.swift                # Core while-loop: LLM → tools → repeat
│   │   │   ├── QueryContext.swift             # Shared context for a query run
│   │   │   ├── ConversationMessage.swift      # Message types, content blocks
│   │   │   └── AgentError.swift               # Error types (MaxTurnsExceeded, etc.)
│   │   │
│   │   ├── Tools/
│   │   │   ├── Tool.swift                     # Tool protocol
│   │   │   ├── ToolRegistry.swift             # Name → AnyTool mapping
│   │   │   ├── ToolResult.swift               # Normalized result type
│   │   │   ├── ToolExecutionContext.swift      # Context passed to execute()
│   │   │   ├── AnyTool.swift                  # Type-erased wrapper
│   │   │   ├── JSONSchema.swift               # JSON Schema representation + Codable→Schema helper
│   │   │   └── BuiltIn/
│   │   │       ├── WorkspaceTools.swift        # write_file, read_file, edit_file, list_files
│   │   │       ├── PlanningTools.swift         # write_todos, read_todos
│   │   │       └── CoordinationTools.swift     # task, ask_user
│   │   │
│   │   ├── Providers/
│   │   │   ├── LLMProvider.swift              # Protocol: streamChat()
│   │   │   ├── StreamChunk.swift              # textDelta, messageComplete, retry
│   │   │   ├── ProviderRegistry.swift         # Runtime selection by modelId
│   │   │   ├── OpenAIProvider.swift           # MacPaw/OpenAI SDK
│   │   │   ├── AnthropicProvider.swift        # HTTP + Messages API
│   │   │   └── GoogleProvider.swift           # HTTP + Gemini API
│   │   │
│   │   ├── Coordination/
│   │   │   ├── SubAgentExecutor.swift         # Isolated sub-agent execution
│   │   │   ├── BatchExecutor.swift            # Parallel sub-agents via TaskGroup
│   │   │   └── AskUserHandler.swift           # Pause/resume protocol
│   │   │
│   │   ├── Harness/
│   │   │   ├── HarnessEngine.swift            # Phase state machine
│   │   │   ├── PhaseDefinition.swift          # Phase types and definition
│   │   │   ├── HarnessDefinition.swift        # Complete workflow definition
│   │   │   ├── HarnessRegistry.swift          # Available harnesses
│   │   │   ├── GatekeeperLLM.swift            # Pre-harness validation
│   │   │   └── PostHarnessLLM.swift           # Post-harness summary
│   │   │
│   │   ├── Workspace/
│   │   │   ├── WorkspaceProvider.swift        # Protocol
│   │   │   ├── InMemoryWorkspace.swift        # For testing
│   │   │   └── FileSystemWorkspace.swift      # Local disk
│   │   │
│   │   ├── Streaming/
│   │   │   ├── AgentEvent.swift               # All event types (enum)
│   │   │   ├── AgentStatus.swift              # Status state machine
│   │   │   └── SSEEncoder.swift               # Event → SSE string
│   │   │
│   │   ├── Permissions/
│   │   │   ├── PermissionChecker.swift        # Protocol
│   │   │   ├── PermissionMode.swift           # default, auto, readOnly
│   │   │   └── DefaultPermissionChecker.swift # Configurable implementation
│   │   │
│   │   ├── Hooks/
│   │   │   ├── HookEvent.swift                # preToolUse, postToolUse, stop
│   │   │   ├── HookHandler.swift              # Protocol
│   │   │   └── HookExecutor.swift             # Dispatch hooks
│   │   │
│   │   ├── MCP/
│   │   │   ├── MCPClient.swift                # Protocol
│   │   │   ├── MCPToolBridge.swift            # MCP → ToolRegistry adapter
│   │   │   ├── MCPServerConfig.swift          # Connection config
│   │   │   ├── HTTPMCPClient.swift            # Streamable HTTP transport
│   │   │   └── SSEMCPClient.swift             # SSE transport (MCPO)
│   │   │
│   │   ├── Persistence/
│   │   │   ├── ThreadRepository.swift
│   │   │   ├── MessageRepository.swift
│   │   │   ├── TodoRepository.swift
│   │   │   ├── HarnessRunRepository.swift
│   │   │   └── TokenUsageRepository.swift
│   │   │
│   │   ├── Planning/
│   │   │   ├── TodoManager.swift
│   │   │   └── TodoItem.swift
│   │   │
│   │   └── Models/
│   │       ├── Thread.swift
│   │       ├── Message.swift
│   │       ├── HarnessRun.swift
│   │       ├── TokenUsageRecord.swift
│   │       ├── JSONValue.swift                # Type-safe JSON enum (string, number, bool, array, object, null)
│   │       ├── JSONSchema.swift               # JSON Schema type (object, properties, required, etc.)
│   │       └── ResponseFormat.swift           # LLM response format (.text, .jsonObject, .jsonSchema(JSONSchema))
│   │
│   └── KernelHarnessPostgres/                 # Optional: PostgresNIO implementations
│       ├── PostgresThreadRepository.swift
│       ├── PostgresMessageRepository.swift
│       ├── PostgresTodoRepository.swift
│       ├── PostgresWorkspaceProvider.swift
│       ├── PostgresHarnessRunRepository.swift
│       ├── PostgresTokenUsageRepository.swift
│       └── Migrations/
│           └── CreateAgentTables.swift
│
└── Tests/
    ├── KernelHarnessKitTests/
    │   ├── AgentLoopTests.swift
    │   ├── ToolRegistryTests.swift
    │   ├── HarnessEngineTests.swift
    │   ├── BatchExecutorTests.swift
    │   ├── SubAgentExecutorTests.swift
    │   ├── PermissionCheckerTests.swift
    │   └── SSEEncoderTests.swift
    └── KernelHarnessPostgresTests/
        └── RepositoryIntegrationTests.swift
```

#### Package.swift Dependencies

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KernelHarnessKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "KernelHarnessKit", targets: ["KernelHarnessKit"]),
        .library(name: "KernelHarnessPostgres", targets: ["KernelHarnessPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/MacPaw/OpenAI.git", from: "0.4.0"),
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "KernelHarnessKit",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOCore", package: "swift-nio"),
            ]
        ),
        .target(
            name: "KernelHarnessPostgres",
            dependencies: [
                "KernelHarnessKit",
                .product(name: "PostgresNIO", package: "postgres-nio"),
            ]
        ),
        .testTarget(name: "KernelHarnessKitTests", dependencies: ["KernelHarnessKit"]),
        .testTarget(name: "KernelHarnessPostgresTests", dependencies: ["KernelHarnessPostgres"]),
    ]
)
```

---

## 5. How Nemesis Consumes KernelHarnessKit

```swift
// In nemesis-harness/Sources/configure.swift

import KernelHarnessKit
import KernelHarnessPostgres

func configure(_ app: Application) throws {
    // 1. Providers
    let openai = OpenAIProvider(apiKey: Environment.get("OPENAI_API_KEY")!)
    let anthropic = AnthropicProvider(apiKey: Environment.get("ANTHROPIC_API_KEY"))
    let google = GoogleProvider(apiKey: Environment.get("GOOGLE_AI_API_KEY"))
    let providers = ProviderRegistry(providers: [
        "openai": openai, "anthropic": anthropic, "google": google
    ])

    // 2. Tool Registry (built-in + MCP)
    let toolRegistry = ToolRegistry()
    toolRegistry.registerBuiltIns()                  // workspace, planning, coordination tools

    // Connect to nemesis-api MCP
    let nemesisMCP = HTTPMCPClient(url: URL(string: Environment.get("NEMESIS_MCP_URL")!)!)
    try await MCPToolBridge(client: nemesisMCP).registerTools(into: toolRegistry)

    // Connect to mcp-brasil via MCPO
    let brasilMCP = SSEMCPClient(url: URL(string: Environment.get("MCP_BRASIL_URL")!)!)
    try await MCPToolBridge(client: brasilMCP).registerTools(into: toolRegistry) { tool in
        // Curate to ~30 core legal tools by default
        DefaultBrasilToolFilter.isEnabled(tool)
    }

    // 3. Harness Registry (domain-specific)
    let harnessRegistry = HarnessRegistry()
    harnessRegistry.register(CaseResearchHarness.definition)
    harnessRegistry.register(JudgeAnalysisHarness.definition)
    harnessRegistry.register(JurisprudenceReportHarness.definition)

    // 4. Persistence (PostgresNIO)
    let postgres = PostgresClient(configuration: dbConfig)
    let repos = PostgresRepositories(client: postgres)

    // 5. Wire into Vapor
    app.agentService = AgentService(
        providers: providers,
        toolRegistry: toolRegistry,
        harnessRegistry: harnessRegistry,
        repositories: repos
    )
}
```

The consumer (`nemesis-harness`) owns: routes, auth middleware, domain harness definitions, system prompts in Portuguese, MCP server connections, and the Vapor application lifecycle. The framework owns everything else.

---

## 6. Comparison: KernelHarnessKit vs. OpenHarness

| Aspect | OpenHarness (Python) | KernelHarnessKit (Swift) |
|--------|---------------------|--------------------------|
| **Language** | Python 3.12+ | Swift 6.0+ |
| **Concurrency** | `asyncio.gather()`, subprocess spawning | `TaskGroup`, structured concurrency (in-process) |
| **Tool abstraction** | `BaseTool` ABC + Pydantic `BaseModel` | `Tool` protocol + `Codable` |
| **Schema generation** | Pydantic `model_json_schema()` | Codable reflection / macro |
| **Provider abstraction** | `SupportsStreamingMessages` Protocol | `LLMProvider` protocol |
| **Streaming events** | 7 frozen dataclasses in `StreamEvent` union | `AgentEvent` enum with associated values |
| **Multi-agent** | Subprocess-based swarm (process isolation) | In-process `TaskGroup` (memory isolation via scope) |
| **Deterministic workflows** | Not present | `HarnessEngine` phase state machine (5 phase types) |
| **Permission model** | Default/Auto/Plan modes + path rules | Protocol-based, consumer-configurable |
| **Hook system** | `PreToolUse`/`PostToolUse` via `HookExecutor` | Same pattern, Swift actor-based |
| **Persistence** | In-memory (conversation state) | Protocol-based repositories with PostgresNIO optional target |
| **Workspace** | Local filesystem (cwd-based) | Protocol-based (in-memory, Postgres, filesystem) |
| **Packaging** | Python package (pip) | Swift Package Manager (SPM) |
| **Target** | CLI tool (interactive terminal) | Library (embedded in server applications) |

**Key divergences and why:**

1. **In-process sub-agents vs. subprocesses.** OpenHarness spawns workers as separate OS processes for hard isolation. KernelHarnessKit uses `TaskGroup` children because the batch-analysis pattern (15 concurrent clause analyses) needs low overhead — subprocess spawning per item would be prohibitively expensive. Isolation is achieved through scoped conversation history and curated tool sets, not process boundaries.

2. **Harness engine is new.** OpenHarness is fundamentally an autonomous agent runtime — the model always drives. KernelHarnessKit adds the hard harness (deterministic phase machine) as a first-class execution strategy because domain workflows like "case research" demand predictable, auditable phase progression that the LLM cannot skip or reorder.

3. **Protocol-based persistence.** OpenHarness keeps everything in memory (it's a CLI tool). KernelHarnessKit is a server library where state must survive across requests and reconnections. Repository protocols with optional PostgresNIO implementations let consumers choose their backing store.

4. **No CLI, no UI.** OpenHarness includes a full TUI with keybindings, themes, and vim mode. KernelHarnessKit is headless — it emits events, and the consumer builds the UI.

---

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Premature abstraction before second consumer | Over-engineered interfaces that don't fit real needs | Start protocol-heavy only where OpenHarness validates the pattern; keep Nemesis-specific code in nemesis-harness; refactor boundary when second consumer arrives |
| Swift JSON Schema generation from Codable is non-trivial | Tool schemas may be incomplete or require manual definition | Start with manual `JSONSchema` definitions; add macro-based generation later; OpenAI SDK already handles schema for its tools |
| Structured concurrency cancellation semantics | Sub-agent failures may cascade unexpectedly | Follow OpenHarness pattern: `return_exceptions=True` equivalent — catch errors per sub-agent and return as `ToolResult(isError: true)` |
| LLM provider inconsistencies in tool calling | Different providers handle tools differently (OpenAI parallel, Anthropic sequential preference) | Abstract behind `LLMProvider` protocol; test each provider; document known quirks; set OpenAI as recommended default |
| Memory pressure from concurrent sub-agents | N simultaneous LLM contexts in-process | Configurable `BatchExecutor.concurrency` (default 5); back-pressure via TaskGroup slot limiting |
| Framework coupling to Vapor | Limits consumers using Hummingbird or other Swift HTTP frameworks | Framework has zero Vapor dependency — only `KernelHarnessPostgres` uses PostgresNIO (which is framework-agnostic). SSE encoding is a pure function, not a Vapor response type. |

---

## 8. MVP Scope

The MVP must be sufficient to build nemesis-harness. This means:

**In scope (MVP):**

- Engine: `AgentLoop`, `QueryContext`, `ConversationMessage`, turn limiting
- Tools: `Tool` protocol, `ToolRegistry`, `AnyTool`, all 8 built-in tools
- Providers: `LLMProvider` protocol, `OpenAIProvider` (primary), `AnthropicProvider`
- Coordination: `SubAgentExecutor`, `BatchExecutor`, `AskUserHandler`
- Harness: `HarnessEngine`, all 5 phase types, `HarnessRegistry`, gatekeeper/post-harness LLM
- Workspace: `WorkspaceProvider` protocol, `InMemoryWorkspace`, `PostgresWorkspace`
- Streaming: `AgentEvent` enum, `SSEEncoder`
- Persistence: all repository protocols + PostgresNIO implementations
- MCP: `MCPClient` protocol, `HTTPMCPClient`, `SSEMCPClient`, `MCPToolBridge`
- Planning: `TodoManager`, tools
- Permissions: `PermissionChecker` protocol, `DefaultPermissionChecker`

**Deferred (post-MVP):**

- `GoogleProvider` (Nemesis launches with OpenAI + Anthropic)
- `StdioMCPClient` (no stdio MCP servers in Nemesis deployment)
- Hooks system (useful but not blocking for Nemesis)
- Auto-compaction (context window management — start with simple truncation)
- `FileSystemWorkspace` (not needed for server deployment)
- Macro-based JSON Schema generation (manual schemas are fine for MVP tool count)

---

## 9. Delivery Sequence

| Week | Milestone | Deliverable |
|------|-----------|-------------|
| 1 | Foundation | SPM package scaffold, `LLMProvider` + `OpenAIProvider`, `ConversationMessage`, `AgentEvent` |
| 1-2 | Engine | `AgentLoop`, `QueryContext`, `ToolRegistry`, `AnyTool`, built-in workspace + planning tools |
| 2 | Providers | `AnthropicProvider`, `ProviderRegistry` |
| 2-3 | MCP | `MCPClient` protocol, `HTTPMCPClient`, `SSEMCPClient`, `MCPToolBridge` |
| 3 | Coordination | `SubAgentExecutor`, `BatchExecutor`, `AskUserHandler`, `task` + `ask_user` tools |
| 3-4 | Harness | `HarnessEngine`, all 5 phase types, `HarnessRegistry`, gatekeeper/post-harness |
| 4 | Persistence | Repository protocols, `KernelHarnessPostgres` target with migrations |
| 4-5 | Integration | First nemesis-harness build using KernelHarnessKit; end-to-end chat + harness test |
| 5 | Polish | Permissions, SSE encoding, error handling, documentation, test coverage |

---

## 10. Open Questions

1. **JSON Schema generation strategy.** Swift lacks Pydantic's `model_json_schema()`. Options: (a) manual schema definitions per tool, (b) Swift macro that generates schema from Codable conformance, (c) runtime reflection via Mirror. Recommendation: start with (a), migrate to (b) when tool count grows.

2. **Context window management.** OpenHarness has sophisticated auto-compaction (microcompact → full LLM summarization). For MVP, should KernelHarnessKit ship simple truncation (drop oldest messages) or invest in compaction? Recommendation: simple truncation for MVP, compaction as post-MVP enhancement.

3. **Structured output enforcement.** For `llmSingle` phases, should the framework use OpenAI's `response_format: json_schema` or parse free-form output? Recommendation: use provider-native structured output where available, fall back to JSON extraction + Codable validation.

4. **MCP SDK.** Should KernelHarnessKit depend on `swift-mcp-sdk` or implement the MCP client protocol from scratch? The official SDK may add unnecessary weight. Recommendation: implement a minimal MCP client (JSON-RPC 2.0 over HTTP/SSE) — the protocol is simple enough that a dependency isn't justified for the client side.

5. **Thread safety model.** The `HarnessEngine` uses `actor` for safe mutation. Should `ToolRegistry` also be an actor, or is `@unchecked Sendable` with a lock sufficient? Recommendation: `ToolRegistry` is write-once-read-many — register at startup, read during execution. A lock-free immutable snapshot pattern is sufficient.
