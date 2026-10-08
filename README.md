# KernelHarnessKit

**Swift infrastructure for custom AI agent harnesses.**

Foundation Models sessions and tools · Multi-agent coordination · Deterministic workflow engine ·
Workspace · Permissions · Persistence · Streaming — everything you need to ship a
custom agent service, minus the model heavy lifting Apple now provides.

[![Swift 6.4+](https://img.shields.io/badge/swift-6.4+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2027%20%7C%20iOS%2027%20%7C%20watchOS%2027-blue)](#platforms)
[![Docs](https://img.shields.io/badge/docs-DocC-blue.svg)](https://murilxaraujo.github.io/KernelHarnessKit/documentation/kernelharnesskit/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Why this exists

> *"The model is commoditized. Structured enforcement of process is the moat."*

KernelHarnessKit focuses on the harness layer around model execution:
workspace, permission gates, deterministic phases, tool curation, streaming,
and multi-agent coordination. Apple's Foundation Models framework supplies
the model, session, transcript, structured generation, streaming, and tool
calling abstractions. KernelHarnessKit builds orchestration and app policy on
those APIs.

KernelHarnessKit gives you two complementary execution strategies, so you can pick
per-task:

1. **Autonomous agents** (soft harness) — the model drives, you curate the tools.
   `runAgent(context:initialMessages:)` returns a streaming event source.
2. **Deterministic phase machines** (hard harness) — the system drives, the model
   executes within each constrained phase. Five phase types cover the common
   shapes of domain work (programmatic, single model call, agent loop, batch
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

Full documentation lives at
[murilxaraujo.github.io/KernelHarnessKit](https://murilxaraujo.github.io/KernelHarnessKit/documentation/kernelharnesskit/) —
articles, tutorials, and API reference. Generate it locally with
`swift package generate-documentation --target KernelHarnessKit`.

## Foundation Models-first

Pass Apple's `SystemLanguageModel` or any provider package's Foundation Models
`LanguageModel` directly:

```swift
let local = SystemLanguageModel.default
let pcc = PrivateCloudComputeLanguageModel()

let context = QueryContext(
    model: pcc,
    toolRegistry: registry,
    permissionChecker: permissions,
    workspace: workspace,
    systemPrompt: "Execute the current harness phase."
)
```

The target minimum is the Foundation Models 27.0 platform generation. Provider
packages that conform to Apple's `LanguageModel` protocol plug into the same
native session API.

## Feature matrix

| Subsystem | What it gives you |
|---|---|
| **Engine** | `AsyncThrowingStream` agent loop with parallel tool dispatch and turn budget. |
| **Tools** | `HarnessTool` protocol, type-erased `AnyTool`, lock-protected `ToolRegistry`, 14 built-in tools (10 on non-macOS platforms). |
| **Models** | Apple Foundation Models `LanguageModelSession` and native tool adapters. |
| **Coordination** | `SubAgentExecutor`, `BatchExecutor` with concurrency control, `AskUserHandler`. |
| **Harness** | `HarnessEngine` actor running 5 phase types with per-phase timeouts. |
| **Workspace** | `WorkspaceProvider` protocol with `InMemoryWorkspace` and `LocalFileWorkspace` implementations. |
| **Streaming** | `AgentEvent` enum covering 18 event kinds, `SSEEncoder` for HTTP transports. |
| **Permissions** | `default` / `auto` / `readOnly` / custom policy with glob-based path rules. |
| **MCP** | JSON-RPC 2.0 over HTTP + SSE, `MCPToolBridge` to register server tools into a local `ToolRegistry`. |
| **Persistence** | Protocol-based repositories for threads, messages, todos, harness runs, and token usage. |

## Platforms

- macOS 27+
- iOS 27+, watchOS 27+

Tests cover workflow, permission, workspace, and persistence behavior without
requiring model credentials.

## Installation

Add the package and `KernelHarnessKit` product to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/murilxaraujo/KernelHarnessKit.git", from: "0.3.0"),
],
targets: [
    .target(
        name: "YourApp",
        dependencies: [
            .product(name: "KernelHarnessKit", package: "KernelHarnessKit"),
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
