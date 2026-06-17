# KernelHarnessKit

**Swift infrastructure for custom AI agent harnesses.**

Harness model facade · Tool system · Multi-agent coordination · Deterministic workflow engine ·
FoundationModels adapters · Workspace · Streaming — everything you need to ship a
custom agent service, minus the model heavy lifting Apple now provides.

[![Swift 6.0+](https://img.shields.io/badge/swift-6.0+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/platforms-macOS%2014%20%7C%20iOS%2017%20%7C%20Linux-blue)](#platforms)
[![Docs](https://img.shields.io/badge/docs-DocC-blue.svg)](https://murilxaraujo.github.io/KernelHarnessKit/documentation/kernelharnesskit/)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

---

## Why this exists

> *"The model is commoditized. Structured enforcement of process is the moat."*

KernelHarnessKit now focuses on the harness layer around model execution:
workspace, permission gates, deterministic phases, tool curation, streaming,
and multi-agent coordination. On Xcode 27, Apple's FoundationModels framework
can run the optimized model stack — System Language Model, Private Cloud
Compute, Core AI, MLX, or third-party `LanguageModel` packages — behind the
same harness abstractions.

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
import KernelHarnessFoundationModels

let registry = ToolRegistry()
registry.registerBuiltIns()

let context = QueryContext(
    harnessModel: AppleHarnessModels.system(),
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

## FoundationModels-first

On Apple platforms with Xcode 27, add the `KernelHarnessFoundationModels`
product and pass any FoundationModels `LanguageModel` through the harness:

```swift
let local = AppleHarnessModels.system()
let pcc = AppleHarnessModels.privateCloudCompute()

let context = QueryContext(
    harnessModel: pcc,
    toolRegistry: registry,
    permissionChecker: permissions,
    workspace: workspace,
    systemPrompt: "Execute the current harness phase."
)
```

The core target does not import FoundationModels, so harness definitions,
workspaces, permissions, persistence, MCP bridging, and Linux/server code stay
portable. OpenAI-compatible provider code remains in-tree while the package is
being re-centered, but new integrations should target `HarnessModel` instead
of `LLMProvider`.

## Feature matrix

| Subsystem | What it gives you |
|---|---|
| **Engine** | `AsyncThrowingStream` agent loop with parallel tool dispatch and turn budget. |
| **Tools** | `Tool` protocol, type-erased `AnyTool`, lock-protected `ToolRegistry`, 8 built-in tools. |
| **Models** | Cross-platform `HarnessModel` facade plus Apple FoundationModels adapter target. |
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
