# KernelHarnessKit — High-Level Design

**Status:** Draft — current product boundary and delivery scope are defined in [Milestone 0: GUI-Ready Core Foundation](Milestone%200%20-%20GUI-Ready%20Core.md). This HLD includes historical Nemesis design material; see the section labels below.
**Date:** 2026-04-20
**Authors:** Murilo Araujo, Claude

---

## 1. Purpose

KernelHarnessKit is an open-source, low-level Swift harness library. It provides model orchestration, permission-aware tools, deterministic workflows, workspace capabilities, persistence contracts, and typed events. Foundation Models is the primary model/session interface; Kernel-owned model abstractions must also preserve provider identity, capabilities, configuration, and provider-specific options.

The primary planned consumer is the closed-source **Kernel macOS app**, which imports the package directly and owns composition, presentation, app state, and its SwiftData adapter. **nemesis-harness**, the "Assistente Jurídico" service for the Nemesis judicial analysis platform, is a second, more complex consumer and a migration target for the evolving session/runtime APIs. The package must support both app and service compositions without requiring either a server or a particular persistence technology.

### Design Philosophy

Adapted from two sources:

From **The AI Automators' Agentic RAG** architecture: *"The model is commoditized. Structured enforcement of process is the moat."* The framework enforces process through two complementary execution strategies — autonomous agents (soft harness) and deterministic phase machines (hard harness) — giving consumers a spectrum between LLM freedom and system control.

From **OpenHarness** (HKUDS): the insight that an agent is decomposable into a small set of orthogonal subsystems — engine, tools, permissions, hooks, coordination, memory, streaming — each with clean interfaces. OpenHarness proves this decomposition works in Python with 43+ tools and multi-agent swarms. KernelHarnessKit ports these patterns to Swift, exploiting structured concurrency (`TaskGroup`, `AsyncStream`) for the sub-agent and batch patterns that are central to the hard harness model.

### What This Is Not

KernelHarnessKit uses Apple's Foundation Models APIs as its common model/session path and accepts conforming provider packages. A Kernel model-interface extension carries provider-specific capabilities that the common Foundation Models surface does not express. The package is not a UI framework and does not require an HTTP server. It is the orchestration layer between model execution, tools, durable sessions, and consumer-defined workflows.

---

## 2. Architecture Overview

```
Kernel macOS app (primary)                nemesis-harness (complex service)
┌──────────────────────────┐             ┌──────────────────────────┐
│ SwiftUI, app composition │             │ Vapor routes, auth,      │
│ SwiftData adapter,       │             │ domain tools, harnesses,  │
│ Keychain, app policy     │             │ Postgres adapter         │
└────────────┬─────────────┘             └────────────┬─────────────┘
             │ direct Swift package API               │
             └────────────────────┬───────────────────┘
                                  ▼
┌─────────────────────────────────────────────────────────────────────┐
│ KernelHarnessKit — UI- and persistence-implementation independent   │
│                                                                     │
│ Session/runtime coordinator · Foundation Models + model extension  │
│ Typed events · tools · permission policy · workspace · persistence  │
│ contracts · MCP · deterministic phase harnesses · coordination     │
└─────────────────────────────────────────────────────────────────────┘
                                  ▲
                                  │ conformers/adapters
                   System · OpenAI-compatible · Anthropic · custom

Optional test/development CLI ─────┘ (exercises the same public API)
```

The diagram shows the target boundary, not the current package manifest. The current SwiftPM package declares macOS 27, iOS 27, and watchOS 27, publishes one `KernelHarnessKit` library product, and has no app/UI or database runtime dependency. Persistence adapters are consumer-owned: SwiftData for the Kernel app and a suitable service adapter, such as Postgres, for Nemesis. The Core library remains directly embeddable and transport-neutral. Confirm the app's actual deployment target before changing the package platform declarations.

---

## 3. Subsystem Specifications

The subsystem specifications and code snippets below include proposals from
the original design draft; they are not all descriptions of implemented APIs.
For current behavior, inspect the package sources. The GUI-ready runtime API is
defined by Milestone 0 Task 0.2; update these specifications and both consumer
examples against that API as implementation proceeds.

For the first runtime version, a session admits one active turn. A concurrent
submission returns a typed busy result; durable queue and steer semantics are
deferred.

### 3.1 Engine — The Agent Loop

The engine is the heartbeat: a `while` loop that calls the LLM, dispatches tool calls, appends results, and repeats until the model stops requesting tools or a turn limit is reached.

**Inspiration from OpenHarness:** The `run_query()` function in OpenHarness implements exactly this pattern — streaming from the API, handling `ApiTextDeltaEvent` / `ApiMessageCompleteEvent`, executing tools (single sequential, multiple concurrent via `asyncio.gather`), and looping. KernelHarnessKit ports this to Swift `AsyncThrowingStream` and `TaskGroup`.

#### Core Types

```swift
/// Shared context for a single query run.
public struct QueryContext: Sendable {
    public let model: any LanguageModel
    public let toolRegistry: ToolRegistry
    public let permissionChecker: PermissionChecker
    public let workspace: any WorkspaceProvider
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

                // 1. Stream from the Foundation Models session. The session
                // owns transcript state and native tool execution.
                let stream = context.session.streamResponse(to: prompt)

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

- Foundation Models owns tool-call scheduling and the transcript lifecycle; KernelHarnessKit applies its permission policy inside each tool adapter.
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

### 3.3 Model execution — Foundation Models and provider extensions

Foundation Models is KernelHarnessKit's primary common interface. The runtime
uses `LanguageModel` / `LanguageModelSession` for supported provider behavior,
including streaming and tools. The Kernel app and Nemesis service configure
models through a Kernel-owned model boundary rather than constructing session
objects inside their UI or route handlers.

The Kernel boundary must expose model/provider identity, declared capabilities,
configuration, and a typed extension for provider-specific features that
Foundation Models does not represent. Credentials are supplied or resolved by
the consumer and are not part of persisted session records. Initial provider
validation targets a mock and an OpenAI-compatible Chat Completions conformer;
`FoundationModelsUtilities` is the preferred candidate for the latter, subject
to the compatibility spike in the milestone plan. Anthropic and custom
conformers remain valid future providers.

Each session has a persisted default model reference; each run records the
model actually used. Changing the session default affects future turns and
does not rewrite prior run history.

KernelHarnessKit owns orchestration, tool selection, `ToolExecutionContext`,
permission evaluation, and projection into its own events and durable domain
state. A Foundation Models session is an execution object, not the durable
source of truth for a conversation. Fixed structured output can use
`@Generable`; runtime-defined output can use `DynamicGenerationSchema` and
`GenerationSchema` where the selected provider supports them.

### 3.4 Streaming — The Event Layer

All agent activity is surfaced as a typed event stream. The Kernel app consumes
the stream directly; a service consumer such as Nemesis may adapt it to SSE or
another transport. Transport encoding is an optional adapter, not the runtime
event contract. Session, turn, message, and tool-call identifiers must let the
consumer associate events with durable state.

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
/// Optional adapter: encode AgentEvent as an SSE line for service consumers.
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
    public let model: any LanguageModel
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

When the `ask_user` tool is called, the engine invokes this handler and
suspends until the consumer supplies a response. The Kernel app can resume the
operation through its direct Core integration; a service consumer may expose a
resume endpoint. The runtime does not require an HTTP transport.

### 3.6 Harness Engine — Deterministic Workflows

The harness engine is the "hard harness" — a phase state machine where the system controls flow and the LLM executes within constrained phases.

**This is a differentiator.** OpenHarness provides the agent loop and coordination but does not have a concept of deterministic phase machines. The phase engine originated from Nemesis workflow requirements and remains a general-purpose Core capability for future app workflows, including Kernel review harnesses.

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
                model: context.model,
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
| `LocalFileWorkspace` | Local filesystem | Project workspaces, app and local development |
| Consumer adapter | Consumer-selected storage | For example, a service-owned Postgres workspace if required |

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

### 3.11 Persistence — Consumer-Provided Adapters

KernelHarnessKit defines persistence contracts; consumers provide storage
implementations appropriate to their platform. The Kernel macOS app will use
SwiftData behind an app-owned adapter. Nemesis may use a service database such
as Postgres. Core domain types and session orchestration do not depend on either
implementation. Existing repository protocols remain reusable where they fit,
but a durable session, message, tool-lifecycle, and run-state contract is still
required for the GUI-ready runtime. Persisted records are authoritative in the
first milestone; events are a live stream emitted after durable state changes,
not a stored event journal. Text deltas may be ahead of the latest durable
assistant checkpoint; the Task 0.3 proposal in [Milestone 0](Milestone%200%20-%20GUI-Ready%20Core.md)
sets the bound to 1 second or 4 KiB of new UTF-8 text, whichever comes first,
with flushes at lifecycle boundaries and graceful cancellation.

The GUI-ready coordinator uses one atomic, coordinator-facing `SessionStore`
contract. The repository protocols sketched below remain useful for existing
consumers and may be used inside an adapter, but separate repository calls are
not sufficient for atomic turn admission, tool intent/result ordering, or
recovery. The milestone document defines the proposed store operations and
recovery rules.

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

The current `Package.swift` publishes one library product and does not declare
the Postgres sources as a target. The older optional `KernelHarnessPostgres`
target shown in this HLD is a historical proposal, not a current package
guarantee. A Postgres adapter can be restored or maintained separately if the
Nemesis migration needs it; it must not become a dependency of the Core product.

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

The following tree and manifest sketch are a **conceptual design from the
original Nemesis-oriented draft**, not a description of the current checkout.
The current package publishes only `KernelHarnessKit`; use `Package.swift` and
`swift package describe` as the source of truth for present targets. The GUI-
ready milestone will evolve the existing layout rather than require this exact
folder structure. Any persistence/provider adapters must remain optional and
must not make the Core product depend on SwiftData, a server framework, or a
single provider SDK.

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
│   │   │   └── Foundation Models LanguageModel and LanguageModelSession
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
│   │       └── FoundationModels Generable / GenerationSchema
│   │
│   └── KernelHarnessPostgres/                 # Historical optional adapter proposal; not a current target
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
    platforms: [.macOS(.v27), .iOS(.v27), .watchOS(.v27)],
    products: [
        .library(name: "KernelHarnessKit", targets: ["KernelHarnessKit"]),
        .library(name: "KernelHarnessPostgres", targets: ["KernelHarnessPostgres"]),
    ],
    dependencies: [
        .package(url: "https://github.com/vapor/postgres-nio.git", from: "1.21.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        .target(
            name: "KernelHarnessKit",
            dependencies: [
                .product(name: "FoundationModels", package: "FoundationModels"),
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

## 5. Consumer integrations: Kernel and Nemesis

### 5.1 Kernel macOS app — primary GUI consumer

The Kernel app consumes the Swift package directly; no local HTTP server or
OpenCode-compatible API sits between the app and Core. The app composes the
runtime and owns SwiftUI, view models, navigation, app policy, credentials,
and SwiftData. Core owns the session/runtime behavior and exposes injected
interfaces for model configuration, storage, workspace access, tools, and
permission policy. Core also owns platform-neutral `Project` and `Location`
domain models. A Project groups one or more Locations; each Location stores a
standardized root URL for a concrete working directory, and a session references
one Location. The app supplies persistence, path selection UI, sandbox/bookmark
resolution, and the workspace implementation.

The intended interaction is: configure a Kernel model and app adapters; create
or reopen a workspace-scoped session; submit a turn; consume typed events; answer
approval requests or cancel; then reload the session from the app's persistence
adapter. The Task 0.2 domain, event, and coordinator contract is specified as a
reviewable proposal in [Milestone 0](Milestone%200%20-%20GUI-Ready%20Core.md);
Task 0.3 and Task 0.4 define its storage and provider implementation details.

**Composition example (behavioral sketch, not compilable API):**

1. The app selects a model descriptor and supplies its credential resolver.
2. The app creates a Core runtime with its SwiftData-backed session store,
   project-root workspace, tool registry, and app-defined permission policy.
3. A view model asks Core to create or reopen a session and submits user input.
4. The view model consumes typed events to render text and tool progress; for an
   approval event, it presents the app's prompt and sends the user's decision
   back to Core.
5. On relaunch, the app loads the session and ordered messages from its adapter
   through Core and can show the completed or interrupted run state.

This is the smaller consumer example. After the Task 0.2 contract is reviewed
and implemented, DocC should include a compilable version and the Nemesis
migration example should exercise the same contract with additional
server-side capabilities.

### 5.2 Nemesis service — complex consumer and migration target

Nemesis remains a valuable second consumer. It combines domain-specific tools,
MCP servers, deterministic harness definitions, authentication, HTTP routes,
and service persistence. Those concerns remain in `nemesis-harness`; the shared
session/runtime behavior belongs in KernelHarnessKit. As the new public session
and model APIs are defined, Nemesis should migrate to them and serve as a
complex-consumer integration test alongside the Kernel GUI integration.

The migrated example should demonstrate a richer composition than the GUI:
multiple domain tool groups, configured MCP servers, a deterministic phase
workflow, service authentication/routes, and a Postgres-backed storage adapter
owned by the service. It must still use the same Core session and model APIs as
the Kernel app; complexity belongs in the consumer composition, not in a
separate server-only Core API.

The following is the **historical Nemesis integration sketch from the original
HLD**. It records the former composition and is not a statement that the shown
types or Postgres target are in the current package API. Update this example to
the new session/runtime API during the Nemesis migration, preserving its
domain-specific tools, harnesses, MCP composition, and service-owned storage.

```swift
// In nemesis-harness/Sources/configure.swift

import KernelHarnessKit
import KernelHarnessPostgres

func configure(_ app: Application) throws {
    // 1. Foundation Models
    let model = SystemLanguageModel.default

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
        model: model,
        toolRegistry: toolRegistry,
        harnessRegistry: harnessRegistry,
        repositories: repos
    )
}
```

In this historical arrangement, `nemesis-harness` owns routes, auth middleware,
domain harness definitions, Portuguese system prompts, MCP server connections,
and the Vapor application lifecycle. The migrated arrangement should keep those
service responsibilities in Nemesis while using the same durable session and
model/runtime contracts as the Kernel app.

---

## 6. Comparison: KernelHarnessKit vs. OpenHarness

| Aspect | OpenHarness (Python) | KernelHarnessKit (Swift) |
|--------|---------------------|--------------------------|
| **Language** | Python 3.12+ | Swift 6.4+ |
| **Concurrency** | `asyncio.gather()`, subprocess spawning | `TaskGroup`, structured concurrency (in-process) |
| **Tool abstraction** | `BaseTool` ABC + Pydantic `BaseModel` | `Tool` protocol + `Codable` |
| **Schema generation** | Pydantic `model_json_schema()` | Codable reflection / macro |
| **Model abstraction** | Foundation Models `LanguageModel` | `LanguageModel` supplied by Apple or provider packages |
| **Streaming events** | 7 frozen dataclasses in `StreamEvent` union | `AgentEvent` enum with associated values |
| **Multi-agent** | Subprocess-based swarm (process isolation) | In-process `TaskGroup` (memory isolation via scope) |
| **Deterministic workflows** | Not present | `HarnessEngine` phase state machine (5 phase types) |
| **Permission model** | Default/Auto/Plan modes + path rules | Protocol-based, consumer-configurable |
| **Hook system** | `PreToolUse`/`PostToolUse` via `HookExecutor` | Same pattern, Swift actor-based |
| **Persistence** | In-memory (conversation state) | Core storage contracts; app-owned SwiftData for Kernel, service adapter for Nemesis |
| **Workspace** | Local filesystem (cwd-based) | Protocol-based (in-memory, local filesystem, consumer-supplied adapters) |
| **Packaging** | Python package (pip) | Swift Package Manager (SPM) |
| **Target** | CLI tool (interactive terminal) | Embeddable library (Kernel macOS app primary; Nemesis service also consumes it) |

**Key divergences and why:**

1. **In-process sub-agents vs. subprocesses.** OpenHarness spawns workers as separate OS processes for hard isolation. KernelHarnessKit uses `TaskGroup` children because the batch-analysis pattern (15 concurrent clause analyses) needs low overhead — subprocess spawning per item would be prohibitively expensive. Isolation is achieved through scoped conversation history and curated tool sets, not process boundaries.

2. **Harness engine is new.** OpenHarness is fundamentally an autonomous agent runtime — the model always drives. KernelHarnessKit adds the hard harness (deterministic phase machine) as a first-class execution strategy because domain workflows like "case research" demand predictable, auditable phase progression that the LLM cannot skip or reorder.

3. **Protocol-based persistence.** OpenHarness keeps everything in memory (it's a CLI tool). KernelHarnessKit separates durable session behavior from storage technology. Core defines the contracts; Kernel supplies SwiftData and service consumers may supply Postgres or another adapter.

4. **No bundled UI.** OpenHarness includes a full TUI with keybindings, themes, and vim mode. KernelHarnessKit remains headless and emits typed events; the Kernel app builds the UI. A small development/test CLI is optional and is not a product UI.

---

## 7. Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Consumer needs diverge between app and service | App and backend integrations drift or force UI/server concerns into Core | Validate the same session/model contracts with the Kernel app and the more complex Nemesis migration; keep app UI and service routes/adapters outside Core |
| Runtime-defined tool schemas may not map to statically generated tool arguments | Some remote MCP tools may not fit Foundation Models' typed `Tool` API | Adapt supported JSON Schema shapes with `DynamicGenerationSchema`; retain MCP bridge schemas for server-facing metadata |
| Structured concurrency cancellation semantics | Sub-agent failures may cascade unexpectedly | Follow OpenHarness pattern: `return_exceptions=True` equivalent — catch errors per sub-agent and return as `ToolResult(isError: true)` |
| Provider package differences | External model packages may differ in capabilities and availability | Query Foundation Models capabilities and handle unsupported operations at the feature boundary |
| Memory pressure from concurrent sub-agents | N simultaneous LLM contexts in-process | Configurable `BatchExecutor.concurrency` (default 5); back-pressure via TaskGroup slot limiting |
| Framework coupling to a consumer stack | Limits direct app embedding or alternate service hosts | Keep SwiftUI, SwiftData, Vapor, and Postgres adapters outside Core; transport encoders remain optional consumer adapters |

---

## 8. Historical Nemesis MVP Scope (superseded)

This was the original MVP definition for building `nemesis-harness`. It is
preserved as project history, not as the current package roadmap. The agreed
GUI-ready scope and acceptance criteria are in [Milestone 0](Milestone%200%20-%20GUI-Ready%20Core.md).

**In scope (MVP):**

- Engine: `AgentLoop`, `QueryContext`, `ConversationMessage`, turn limiting
- Tools: `Tool` protocol, `ToolRegistry`, `AnyTool`, all 8 built-in tools
- Model runtime: Foundation Models `LanguageModel` and `LanguageModelSession`
- Coordination: `SubAgentExecutor`, `BatchExecutor`, `AskUserHandler`
- Harness: `HarnessEngine`, all 5 phase types, `HarnessRegistry`, gatekeeper/post-harness LLM
- Workspace: `WorkspaceProvider` protocol, `InMemoryWorkspace`, `PostgresWorkspace`
- Streaming: `AgentEvent` enum, `SSEEncoder`
- Persistence: all repository protocols + PostgresNIO implementations
- MCP: `MCPClient` protocol, `HTTPMCPClient`, `SSEMCPClient`, `MCPToolBridge`
- Planning: `TodoManager`, tools
- Permissions: `PermissionChecker` protocol, `DefaultPermissionChecker`

**Deferred (post-MVP):**

- Server-backed model implementations supplied by Foundation Models provider packages
- `StdioMCPClient` (no stdio MCP servers in Nemesis deployment)
- Hooks system (useful but not blocking for Nemesis)
- Auto-compaction (context window management — start with simple truncation)
- `FileSystemWorkspace` (not needed for server deployment)
- Macro-based JSON Schema generation (manual schemas are fine for MVP tool count)

---

## 9. Historical Delivery Sequence (superseded)

The week-by-week sequence below belongs to the original Nemesis MVP and is not
the current delivery plan. Use the ordered tasks in [Milestone 0](Milestone%200%20-%20GUI-Ready%20Core.md).

| Week | Milestone | Deliverable |
|------|-----------|-------------|
| 1 | Foundation | SPM package scaffold, Foundation Models session integration, `ConversationMessage`, `AgentEvent` |
| 1-2 | Engine | `AgentLoop`, `QueryContext`, `ToolRegistry`, `AnyTool`, built-in workspace + planning tools |
| 2 | Model integration | Foundation Models `LanguageModel` implementations and availability handling |
| 2-3 | MCP | `MCPClient` protocol, `HTTPMCPClient`, `SSEMCPClient`, `MCPToolBridge` |
| 3 | Coordination | `SubAgentExecutor`, `BatchExecutor`, `AskUserHandler`, `task` + `ask_user` tools |
| 3-4 | Harness | `HarnessEngine`, all 5 phase types, `HarnessRegistry`, gatekeeper/post-harness |
| 4 | Persistence | Repository protocols, `KernelHarnessPostgres` target with migrations |
| 4-5 | Integration | First nemesis-harness build using KernelHarnessKit; end-to-end chat + harness test |
| 5 | Polish | Permissions, SSE encoding, error handling, documentation, test coverage |

---

## 10. Technical Design Notes

The following notes are implementation topics from the original draft, not
unresolved product-boundary decisions. The current package and Milestone 0 plan
take precedence where they differ.

1. **Tool argument strategy.** The package already has typed tool inputs, JSON Schema descriptions, and a Foundation Models adapter. Preserve those capabilities; validate provider-specific schema support at the model boundary.

2. **Context window management.** Compaction and summarization are deferred beyond the first GUI-ready vertical slice. Do not infer a truncation policy from this historical draft.

3. **Structured output enforcement.** For `llmSingle` phases, use Foundation Models `@Generable` or `GenerationSchema` where supported, then apply application-specific validation before writing phase output.

4. **MCP SDK.** The current package already implements JSON-RPC and HTTP/SSE MCP clients. Reassess dependencies only if future transport or protocol requirements justify them; MCP expansion is outside Milestone 0.

5. **Concurrency model.** The session coordinator must serialize turns per session and expose cancellation explicitly. Existing tools, registries, and deterministic harnesses should retain their Swift 6 concurrency guarantees as their shared APIs evolve.
