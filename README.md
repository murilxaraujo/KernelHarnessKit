# KernelHarnessKit

**Swift infrastructure for custom AI agent harnesses.**

Agent loop · Tool system · Multi-agent coordination · Deterministic workflow engine ·
LLM provider abstraction · Workspace · Streaming — everything you need to ship a
custom agent service, minus the domain details *you* supply.

[![Swift 6.0+](https://img.shields.io/badge/swift-6.0+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2014%20%7C%20iOS%2017%20%7C%20Linux-blue)](#platforms)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Why this exists

> *"The model is commoditized. Structured enforcement of process is the moat."*

KernelHarnessKit gives you two complementary execution strategies, so you can pick
per-task:

1. **Autonomous agents** (soft harness) — the model drives, you curate the tools.
   `runAgent(context:initialMessages:)` returns a streaming event source.
2. **Deterministic phase machines** (hard harness) — the system drives, the model
   executes within each constrained phase. Five phase types cover the common
   shapes of domain work (programmatic, single LLM call, agent loop, batch
   sub-agents, human input).

The framework ports the subsystem decomposition of [OpenHarness](https://github.com/HKUDS/OpenHarness)
(Python) to Swift 6, leveraging structured concurrency (`TaskGroup`,
`AsyncThrowingStream`) for in-process sub-agents and batch phases. It adds an
original contribution — the deterministic phase state machine — because domain
workflows deserve predictable, auditable progression that the LLM cannot
reorder or skip.

## Quick start

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

See the [DocC catalog](Sources/KernelHarnessKit/Documentation.docc/) — generate it with
`swift package generate-documentation --target KernelHarnessKit` — for articles,
tutorials, and full API reference.

## Run the demo

The package ships with a small CLI you can run against any OpenAI-compatible
endpoint:

```bash
export OPENAI_API_KEY=sk-…
swift run kernel-harness-demo chat "write a haiku about deterministic agents"
swift run kernel-harness-demo harness
```

`harness` mode walks through a three-phase workflow: programmatic topic
collection → parallel per-topic analysis via sub-agents → single-call
summarization. Great for seeing every subsystem exercise at once.

## One provider, many vendors

KernelHarnessKit speaks one wire protocol: OpenAI's. Vendor-specific endpoints
(Anthropic, Google Gemini, DeepSeek, Groq, xAI, OpenRouter, Ollama, vLLM,
LM Studio) are reached via their OpenAI-compatible mode. This means a **single
provider implementation** covers the vast majority of production use cases:

```swift
let registry = ProviderRegistry(providers: [
    "openai":    .openai(apiKey: env("OPENAI_API_KEY")),
    "anthropic": .anthropic(apiKey: env("ANTHROPIC_API_KEY")),
    "google":    .google(apiKey: env("GOOGLE_AI_API_KEY")),
    "groq":      .groq(apiKey: env("GROQ_API_KEY")),
])

let provider = registry.provider(for: "anthropic/claude-sonnet-4-5")!
```

A swap-in custom `LLMProvider` conformance is the escape hatch when a vendor's
OpenAI-compat surface is too limited.

## Feature matrix

| Subsystem | What it gives you |
|---|---|
| **Engine** | `AsyncThrowingStream` agent loop with parallel tool dispatch and turn budget. |
| **Tools** | `Tool` protocol, type-erased `AnyTool`, lock-protected `ToolRegistry`, 8 built-in tools. |
| **Providers** | One `OpenAICompatibleProvider` implementation + prefix-routed `ProviderRegistry`. |
| **Coordination** | `SubAgentExecutor`, `BatchExecutor` with concurrency control, `AskUserHandler`. |
| **Harness** | `HarnessEngine` actor running 5 phase types with per-phase timeouts. |
| **Workspace** | `WorkspaceProvider` protocol + `InMemoryWorkspace` (Postgres impl in companion target). |
| **Streaming** | `AgentEvent` enum covering 17 event types, `SSEEncoder` for HTTP transports. |
| **Permissions** | `default` / `auto` / `readOnly` / custom policy with glob-based path rules. |
| **MCP** | JSON-RPC 2.0 over HTTP + SSE, `MCPToolBridge` to register server tools into a local `ToolRegistry`. |
| **Persistence** | Protocol-based repositories with `PostgresNIO` implementations in `KernelHarnessPostgres`. |

## Platforms

- macOS 14+
- iOS 17+, tvOS 17+, watchOS 10+
- Linux (tested via Swift 6.0 Docker images)

Tests run offline against a `MockLLMProvider`; no API keys required.

## Installation

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/murilxaraujo/KernelHarnessKit.git", from: "0.1.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "KernelHarnessKit", package: "KernelHarnessKit"),
            // Optional: Postgres-backed repositories for server deployments
            .product(name: "KernelHarnessPostgres", package: "KernelHarnessKit"),
        ]
    )
]
```

## Design

See [the high-level design document](Kernel%20Harness/KernelHarnessKit-HLD.md) for
the subsystem-by-subsystem rationale, the comparison to OpenHarness, and
the delivery plan.

## License

MIT. See [LICENSE](LICENSE).
