#  Harness

Deterministic, phase-based workflows.

## Overview

A harness is an authored sequence of phases that the ``HarnessEngine``
runs top-to-bottom. Each phase:

- Has a scoped, focused ``PhaseDefinition/systemPrompt`` (5–15 lines).
- Receives a curated set of tools (``PhaseDefinition/tools``).
- Reads from and writes to the shared ``WorkspaceProvider``.
- Optionally enforces a ``PhaseDefinition/timeout``.

Five execution strategies cover the common shapes of domain work:

| Case | When to use |
|---|---|
| `PhaseExecution.programmatic` | Pure Swift. Extract, parse, transform — no LLM needed. |
| `PhaseExecution.llmSingle` | One LLM call with optional structured output. |
| `PhaseExecution.llmAgent` | Scoped deep mode — the model gets a curated toolset and a turn budget. |
| `PhaseExecution.llmBatchAgents` | Fan out per-item sub-agents with back-pressure. |
| `PhaseExecution.llmHumanInput` | Pause the harness and wait for user input. |

### Authoring a harness

```swift
let collect = PhaseDefinition(
    name: "collect",
    description: "Gather topics",
    systemPrompt: "",
    workspaceOutput: "topics.txt",
    execution: .programmatic { _ in "swift concurrency\nactors\ndistributed actors" }
)

let analyze = PhaseDefinition(
    name: "analyze",
    description: "Produce a bullet per topic",
    systemPrompt: "You are a concise Swift writer. One sentence per topic.",
    workspaceOutput: "analysis.md",
    execution: .llmBatchAgents(
        concurrency: 3,
        itemsLoader: { ctx in
            let raw = try await ctx.workspace.readFile(path: "topics.txt")
            return raw.split(separator: "\n").enumerated().map { i, topic in
                PhaseBatchItem(id: "\(i)", content: String(topic))
            }
        },
        itemPromptBuilder: { "Summarize: \($0.content)" },
        maxTurnsPerItem: 2,
        resultFormatter: { results in
            results.map { "- \($0.output)" }.joined(separator: "\n")
        }
    )
)

let definition = HarnessDefinition(
    type: "topic_digest",
    displayName: "Topic Digest",
    description: "Gather → analyze → done",
    phases: [collect, analyze]
)
```

### Running

```swift
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

### Resumability

Because phases pass context through the workspace, a harness interrupted
mid-run is naturally resumable: re-run the same definition against the
same workspace and phases with already-written outputs finish instantly.
The MVP does not yet short-circuit phases whose output exists — that's a
consumer concern for now. The repository shapes
(``HarnessRunRepository``, ``WorkspaceProvider``) support the pattern and
the `KernelHarnessPostgres` target provides the persistence.

### Gatekeeper and post-harness phases

Optional ``HarnessDefinition/gatekeeper`` and
``HarnessDefinition/postHarness`` phases run before and after the main
sequence. Typical uses:

- **Gatekeeper**: verify required uploads are present, greet the user, set
  metadata for downstream phases.
- **Post-harness**: produce a conversational summary of the run suitable
  for sending back over the chat transport.

Both are regular ``PhaseDefinition`` values, so every execution strategy
is available to them.
