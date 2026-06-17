# Spike: Claude Code CLI as LLMProvider

**Date:** 2026-04-23
**Status:** Complete
**Author:** Murilo + Claude

## Problem Statement

We want to use a Claude Max subscription (authenticated via `claude auth login`) through KernelHarnessKit's `LLMProvider` protocol. Anthropic restricts Max subscription usage to official products — Claude Code CLI is one of them. The question: can we use the CLI as a subprocess-based router so KernelHarnessKit gets Claude completions without needing a separate API key?

## TL;DR

**Yes, viable.** Two complementary approaches, ship both:

| Approach | Fits `LLMProvider`? | Tool support | Effort | Best for |
|----------|---------------------|-------------|--------|----------|
| **A — `ClaudeCodeProvider`** | Yes | KHK's own tools | ~300 LOC, 2-3 days | Text phases, structured output |
| **B — `ClaudeCodeAgentRunner`** | No (new protocol) | CC's built-in tools | ~500 LOC, 4-5 days | Agentic phases needing Bash/file I/O |

## Architecture

### The Impedance Mismatch

Claude Code CLI is **not a thin LLM proxy**. When you run `claude -p`, it spins up its own agent loop with its own system prompt, tools (Bash, Read, Write, Edit, Glob, Grep), and multi-turn orchestration. KernelHarnessKit also has its own agent loop (`runAgent` in `AgentLoop.swift`). Running both creates a double-loop problem: two systems competing to execute tools, inject system prompts, and manage turns.

The key realization: we don't fight the architecture, we pick which loop owns what.

### Approach A — `ClaudeCodeProvider: LLMProvider`

Use Claude Code as a **text completion engine only**. Disable its tools, limit to 1 turn, parse the streaming output.

```
┌─────────────────────┐     ┌──────────────────────┐
│  KernelHarnessKit   │     │  ClaudeCodeProvider   │
│  ─────────────────  │     │  ───────────────────  │
│  Agent Loop         │────▶│  LLMProvider protocol │
│  Tool Registry      │     │  Spawns subprocess    │
│  Permission Checker │     │  Parses NDJSON stream │
└─────────────────────┘     └──────────┬───────────┘
                                       │
                            ┌──────────▼───────────┐
                            │  claude -p "..."      │
                            │  --output-format      │
                            │    stream-json        │
                            │  --max-turns 1        │
                            │  --tools ""           │
                            │  --bare               │
                            └──────────────────────┘
```

**How it works:**

1. `streamChat()` serializes the conversation history + tool schemas into a prompt
2. Spawns `claude -p` as a `Process` with stream-json output
3. Parses NDJSON lines from stdout into `StreamChunk` events
4. Claude Code's own tools are disabled (`--tools ""`), so the model only sees KHK's tool schemas embedded in the prompt
5. KHK's agent loop handles tool execution as usual

**Critical flags:**

- `--bare` — skip project discovery, faster startup
- `--tools ""` — disable all Claude Code built-in tools
- `--max-turns 1` — single completion, no internal looping
- `--output-format stream-json` — NDJSON event stream on stdout
- `--verbose` — include usage data in events
- `--include-partial-messages` — stream text deltas

**Limitations:**

- Claude Code still injects its own system prompt preamble (the "you are Claude Code" framing). With `--bare` and `--tools ""` this is minimal, but it's there.
- Each "turn" spawns a new process (~200-500ms cold start). For multi-turn agentic loops, this adds up. Mitigated by `--session-id` for session reuse.
- Tool call format: Claude Code's model sees an Anthropic-native tool format, not OpenAI's. The model may return tool calls in Anthropic's `tool_use` content block format rather than OpenAI's `function` format. The provider must handle both.

### Approach B — `ClaudeCodeAgentRunner`

Use Claude Code as the **entire agent** — let it run its own tools, its own loop. KernelHarnessKit orchestrates at the *phase* level, not the turn level.

```
┌─────────────────────┐     ┌──────────────────────┐
│  HarnessEngine      │     │ ClaudeCodeAgentRunner │
│  ─────────────────  │     │  ───────────────────  │
│  Phase orchestration│────▶│  New execution mode   │
│  Workspace I/O      │     │  Full CC agent loop   │
│  Event routing      │     │  CC's own tools       │
└─────────────────────┘     └──────────┬───────────┘
                                       │
                            ┌──────────▼───────────┐
                            │  claude -p "..."      │
                            │  --output-format      │
                            │    stream-json        │
                            │  --max-turns 50       │
                            │  --permission-mode    │
                            │    acceptEdits        │
                            └──────────────────────┘
```

**How it works:**

1. A new `PhaseExecution` case: `.claudeCode(promptBuilder:maxTurns:permissionMode:)`
2. Spawns `claude -p` with the phase prompt, lets it run its full agent loop
3. Translates CC's NDJSON events into `AgentEvent` for the harness event stream
4. When complete, reads the `result` event as the phase output

**This is the right choice when** the task needs file system access, shell commands, or multi-turn reasoning — exactly what Claude Code is built for.

## Type Mapping

### NDJSON Events → StreamChunk (Approach A)

```
CC stream event                          KHK StreamChunk
─────────────────────────────────────    ──────────────────────────
content_block_delta.text_delta.text  →   .textDelta(text)
content_block_start (type: tool_use) →   .toolCallDelta(index, id, name, nil)
content_block_delta.input_json_delta →   .toolCallDelta(index, nil, nil, chunk)
message_delta.usage                  →   (accumulate into UsageSnapshot)
message_stop                         →   .messageComplete(message, usage)
```

### NDJSON Events → AgentEvent (Approach B)

```
CC stream event                          KHK AgentEvent
─────────────────────────────────────    ──────────────────────────
content_block_delta.text_delta       →   .textChunk(text)
tool_use content block start         →   .toolExecutionStarted(callId, name, input)
tool result in subsequent turn       →   .toolExecutionCompleted(callId, name, result)
result (subtype: success)            →   .turnComplete(message, usage)
result (subtype: error)              →   .error(description)
```

### ConversationMessage Serialization

For Approach A, the conversation history must be serialized into the `-p` prompt. Since Claude Code expects a single string prompt (not a message array), we need to flatten:

```swift
func serializeHistory(_ messages: [ConversationMessage], systemPrompt: String?) -> String {
    var parts: [String] = []
    if let sys = systemPrompt { parts.append("[System]\n\(sys)") }
    for msg in messages {
        switch msg.role {
        case .system: parts.append("[System]\n\(msg.plainText)")
        case .user: parts.append("[User]\n\(msg.plainText)")
        case .assistant: parts.append("[Assistant]\n\(msg.plainText)")
        case .tool:
            for block in msg.content {
                if case .toolResult(let id, let content, let isError) = block {
                    parts.append("[ToolResult:\(id)]\n\(isError ? "ERROR: " : "")\(content)")
                }
            }
        }
    }
    return parts.joined(separator: "\n\n")
}
```

**Alternative (better):** Use `--input-format stream-json` to pipe structured messages via stdin. This preserves the conversation structure without lossy flattening. Needs investigation — the exact stdin JSON schema for multi-turn input isn't fully documented yet.

## Code Sketch: ClaudeCodeProvider

```swift
import Foundation

/// An ``LLMProvider`` that routes completions through the local Claude Code CLI,
/// using the user's authenticated Max subscription.
public struct ClaudeCodeProvider: LLMProvider {
    /// Path to the `claude` binary. Defaults to finding it in $PATH.
    public let executablePath: String

    /// Extra CLI flags passed to every invocation.
    public let extraFlags: [String]

    /// Whether to use `--bare` mode (skip project discovery).
    public let bare: Bool

    public init(
        executablePath: String = "claude",
        extraFlags: [String] = [],
        bare: Bool = true
    ) {
        self.executablePath = executablePath
        self.extraFlags = extraFlags
        self.bare = bare
    }

    public func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        // Flatten conversation into a prompt string.
        let prompt = serializeConversation(messages, systemPrompt: systemPrompt, tools: tools)

        // Build the argument list.
        var args = ["--print", prompt, "--output-format", "stream-json"]
        args += ["--max-turns", "1", "--tools", ""]
        args += ["--verbose", "--include-partial-messages"]
        if bare { args.append("--bare") }
        args += extraFlags

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                    process.arguments = [executablePath] + args

                    let pipe = Pipe()
                    process.standardOutput = pipe

                    try process.run()

                    let handle = pipe.fileHandleForReading
                    var textAccumulator = ""
                    var toolAccumulator = ToolCallAccumulator()
                    var usage = UsageSnapshot()

                    // Read NDJSON lines from stdout.
                    for try await line in handle.bytes.lines {
                        try Task.checkCancellation()
                        guard let data = line.data(using: .utf8),
                              let event = try? JSONDecoder().decode(CLIEvent.self, from: data)
                        else { continue }

                        switch event.classify() {
                        case .textDelta(let text):
                            textAccumulator.append(text)
                            continuation.yield(.textDelta(text))

                        case .toolCallStart(let index, let id, let name):
                            continuation.yield(.toolCallDelta(index: index, id: id, name: name, argumentsChunk: nil))

                        case .toolCallDelta(let index, let chunk):
                            toolAccumulator.append(index: index, chunk: chunk)
                            continuation.yield(.toolCallDelta(index: index, id: nil, name: nil, argumentsChunk: chunk))

                        case .usageUpdate(let prompt, let completion):
                            usage = UsageSnapshot(promptTokens: prompt, completionTokens: completion)

                        case .messageStop:
                            break // handled after loop

                        case .ignored:
                            break
                        }
                    }

                    process.waitUntilExit()

                    // Build the final ConversationMessage.
                    var content: [ContentBlock] = []
                    if !textAccumulator.isEmpty {
                        content.append(.text(textAccumulator))
                    }
                    for call in toolAccumulator.build() {
                        content.append(.toolUse(id: call.id, name: call.name, input: call.input))
                    }
                    let message = ConversationMessage(role: .assistant, content: content)
                    continuation.yield(.messageComplete(message, usage))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
```

## Code Sketch: NDJSON Event Types

```swift
/// Raw NDJSON event from `claude --output-format stream-json`.
struct CLIEvent: Decodable {
    let type: String
    let subtype: String?
    let event: StreamEvent?
    let result: String?
    let session_id: String?

    struct StreamEvent: Decodable {
        let type: String
        let index: Int?
        let delta: Delta?
        let content_block: ContentBlock?
        let usage: Usage?

        struct Delta: Decodable {
            let type: String?
            let text: String?
            let partial_json: String?
            let stop_reason: String?
        }

        struct ContentBlock: Decodable {
            let type: String?
            let id: String?
            let name: String?
        }

        struct Usage: Decodable {
            let input_tokens: Int?
            let output_tokens: Int?
        }
    }

    enum Classified {
        case textDelta(String)
        case toolCallStart(index: Int, id: String, name: String)
        case toolCallDelta(index: Int, chunk: String)
        case usageUpdate(prompt: Int, completion: Int)
        case messageStop
        case ignored
    }

    func classify() -> Classified {
        guard type == "stream_event", let event else {
            if type == "result" { return .messageStop }
            return .ignored
        }

        switch event.type {
        case "content_block_delta":
            if event.delta?.type == "text_delta", let text = event.delta?.text {
                return .textDelta(text)
            }
            if event.delta?.type == "input_json_delta", let chunk = event.delta?.partial_json {
                return .toolCallDelta(index: event.index ?? 0, chunk: chunk)
            }

        case "content_block_start":
            if event.content_block?.type == "tool_use",
               let id = event.content_block?.id,
               let name = event.content_block?.name {
                return .toolCallStart(index: event.index ?? 0, id: id, name: name)
            }

        case "message_start":
            if let u = event.usage {
                return .usageUpdate(prompt: u.input_tokens ?? 0, completion: u.output_tokens ?? 0)
            }

        case "message_delta":
            if let u = event.usage {
                return .usageUpdate(prompt: u.input_tokens ?? 0, completion: u.output_tokens ?? 0)
            }

        case "message_stop":
            return .messageStop

        default:
            break
        }
        return .ignored
    }
}
```

## Code Sketch: Registration

```swift
// In ProviderRegistry vendor presets:
extension ClaudeCodeProvider {
    /// Default preset using the locally authenticated Claude Code CLI.
    public static func local(
        bare: Bool = true,
        extraFlags: [String] = []
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(bare: bare, extraFlags: extraFlags)
    }
}

// Usage:
let registry = ProviderRegistry(providers: [
    "openai":    .openai(apiKey: env("OPENAI_API_KEY")),
    "anthropic": .anthropic(apiKey: env("ANTHROPIC_API_KEY")),
    "claude":    ClaudeCodeProvider.local(),  // Max subscription, no API key needed
], fallback: "claude")

// Model identifiers:
// "claude/claude-sonnet-4-5" → routed through Claude Code CLI
// "openai/gpt-4o"            → routed through OpenAI API as before
```

## Code Sketch: PhaseExecution.claudeCode (Approach B)

```swift
extension PhaseExecution {
    /// Delegate the entire phase to a Claude Code CLI agent run.
    public static func claudeCode(
        promptBuilder: @Sendable (PhaseContext) async throws -> String,
        maxTurns: Int = 50,
        permissionMode: String = "acceptEdits",
        workingDirectory: String? = nil
    ) -> PhaseExecution {
        // Implementation spawns `claude -p` with the built prompt,
        // streams NDJSON events as AgentEvents through the harness,
        // and captures the final `result` as phase output.
    }
}

// Usage in a HarnessDefinition:
PhaseDefinition(
    name: "implement",
    description: "Implement the feature using Claude Code's tools.",
    systemPrompt: "",
    workspaceOutput: "implementation-log.md",
    execution: .claudeCode(
        promptBuilder: { ctx in
            let spec = try await ctx.workspace.readFile(path: "spec.md")
            return "Implement the following specification:\n\n\(spec)"
        },
        maxTurns: 30
    )
)
```

## Open Questions

1. **`--input-format stream-json` stdin protocol** — Can we pipe structured message arrays instead of flattening to a string? This would give us proper multi-turn without lossy serialization. Needs hands-on testing.

2. **`--system-prompt` flag** — Does this fully *replace* Claude Code's default system prompt, or prepend to it? If it replaces, Approach A gets much cleaner — we pass KHK's system prompt directly and avoid the "two system prompts" problem.

3. **Session persistence** — `--session-id` lets us resume sessions. For multi-turn use in KHK's agent loop, we could keep a single Claude Code session alive across turns instead of spawning a new process each time. This would eliminate cold-start overhead and preserve context.

4. **Tool schema passthrough** — If the model sees both "you are Claude Code" framing AND KHK tool schemas embedded in the prompt, will it try to use Claude Code tools that don't exist? With `--tools ""` the model shouldn't see CC tool definitions, but the system prompt framing might still reference them.

5. **Process lifecycle on macOS/iOS** — `Process` (Foundation) works on macOS. On iOS, spawning subprocesses is not allowed. This provider would be macOS-only. For iOS, an API key provider remains the only option.

## Effort Estimate

| Component | LOC | Days |
|-----------|-----|------|
| `CLIEvent` NDJSON parser + types | ~120 | 0.5 |
| `ClaudeCodeProvider: LLMProvider` | ~180 | 1.5 |
| Unit tests (mocked NDJSON streams) | ~200 | 1 |
| **Approach A total** | **~500** | **3** |
| `ClaudeCodeAgentRunner` + PhaseExecution case | ~300 | 2 |
| Event translator (CC events → AgentEvent) | ~150 | 1 |
| Integration tests | ~200 | 1.5 |
| **Approach B total** | **~650** | **4.5** |
| **Both approaches combined** | **~800** | **5-7** |
| Optional: MCP bridge for KHK tools in CC | ~400 | 3 |

## Recommendation

Ship both approaches as a new `KernelHarnessClaudeCode` target in the package. Approach A slots into the existing `ProviderRegistry` seamlessly — any phase that uses `LLMProvider` works. Approach B adds a new execution mode for phases that need full agentic capabilities. Together they cover the entire spectrum from "I just need a completion" to "run this complex multi-tool task."

Start with Approach A — it's smaller, validates the subprocess + NDJSON parsing core, and that core is reused by Approach B. The MCP bridge (exposing KHK tools to Claude Code) is a stretch goal for a later spike.
