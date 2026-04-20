#  Streaming

Turning engine events into transport frames.

## Overview

Every interesting thing the engine or harness does surfaces as an
``AgentEvent``. Consumers drain the event stream and encode whichever
events their UI needs.

### Event categories

- **Engine**: `textChunk`, `turnComplete`, `toolExecutionStarted`,
  `toolExecutionCompleted`, `status`, `error`.
- **Coordination**: `statusChange`, `todosUpdated`, `subAgentStarted`,
  `subAgentCompleted`.
- **Harness**: `harnessPhaseStart`, `harnessPhaseComplete`,
  `harnessPhaseError`, `harnessComplete`, `harnessBatchStart`,
  `harnessBatchProgress`, `harnessHumanInput`.

See ``AgentEvent`` for the full case list.

### SSE encoding

``SSEEncoder`` turns an ``AgentEvent`` into a valid SSE frame:

```swift
let encoder = SSEEncoder()
for try await event in result.events {
    response.write(encoder.encode(event))
}
```

The `event:` tag is stable across releases — consumers can write clients
that pattern-match on type strings (`agent_text_chunk`,
`harness_phase_start`, etc.) without importing KernelHarnessKit.

### Human-in-the-loop

When a phase uses `PhaseExecution.llmHumanInput`, the engine emits the
`.harnessHumanInput(question:)` event and calls the configured
``AskUserHandler``. A typical HTTP
implementation suspends on a `CheckedContinuation` until the user's
response arrives on a separate endpoint:

```swift
actor HTTPAskUserHandler: AskUserHandler {
    private var pending: [UUID: CheckedContinuation<String, Error>] = [:]

    func askUser(question: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            pending[id] = continuation
            // emit SSE frame with id
        }
    }

    func resolve(id: UUID, response: String) {
        pending.removeValue(forKey: id)?.resume(returning: response)
    }
}
```
