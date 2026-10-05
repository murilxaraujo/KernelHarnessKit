#  The agent loop

How the engine runs a turn, dispatches tools, and streams events.

## Overview

The agent loop creates a Foundation Models `LanguageModelSession` and streams
its response. Apple owns transcript updates and the model/tool loop; the
harness projects results into its transport events:

1. Seed a `LanguageModelSession` with the conversation transcript.
2. Stream Foundation Models snapshots and project them to
   ``AgentEvent/textChunk(_:)`` and ``AgentEvent/turnComplete(_:_:)``.
3. Apple invokes registered `FoundationModels.Tool` adapters and maintains
   tool-call and tool-output transcript entries.

### Why single-vs-concurrent dispatch?

Foundation Models may invoke tools concurrently. The adapter applies the
permission policy for every invocation before executing a harness tool.

### Turn budget

``QueryContext/maxTurns`` caps the loop. The HLD default is 200, matching
OpenHarness. A runaway loop surfaces as ``AgentError/maxTurnsExceeded(_:)``.

### Cancellation

Cancelling the outer `Task` propagates into the stream via
`continuation.onTermination`. The loop exits after the current turn
finishes rather than mid-stream to avoid leaving unanswered tool calls in
the conversation.

### Permission gating

Every tool invocation is checked by the session's ``PermissionChecker``
before the registered ``HarnessTool/execute(_:context:)`` implementation is called. Decisions are categorized as
``PermissionCategory/allowed``, ``PermissionCategory/approvalRequired``, or
``PermissionCategory/denied``. ``DefaultPermissionChecker`` supports `auto`,
`readOnly`, `approvalRequired`, and `custom` modes; `custom` mode can apply
per-tool overrides, command deny-list entries, and filesystem glob rules.

A denied decision emits ``AgentEvent/permissionDenied(callId:toolName:reason:input:)``
and becomes a ``ToolResult`` with ``ToolResult/isError`` set — surfaced to the
model as a regular error result so it can adapt, not as an engine-level
exception.

### Context growth

The MVP does not auto-compact. A future release will add a context-window
budget to ``QueryContext`` and emit a status event as the conversation
approaches it, prompting the consumer to compact or truncate. For now, consumers that run long sessions should monitor usage
and reset the conversation explicitly.
