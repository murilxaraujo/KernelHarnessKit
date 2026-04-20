#  The agent loop

How the engine runs a turn, dispatches tools, and streams events.

## Overview

The agent loop is the heartbeat of every autonomous session. It's a
`while turnCount < maxTurns` state machine around a provider stream:

1. Stream a completion from the ``LLMProvider``.
2. On ``StreamChunk/messageComplete(_:_:)``, append the assistant message
   to the conversation buffer and emit ``AgentEvent/turnComplete(_:_:)``.
3. If the assistant requested tool calls, dispatch them — single calls
   sequentially, multiple calls concurrently via `TaskGroup`.
4. Append a single `tool`-role message carrying every result and loop.
5. When the model returns no tool calls, the loop exits cleanly.

### Why single-vs-concurrent dispatch?

When the model issues *one* tool call, executing it inline keeps event
ordering deterministic — the UI sees `start → result → next turn`.

When the model issues *multiple* calls in a single turn, the engine fans
them out via `TaskGroup` and gathers the results in input order. Parallel
dispatch avoids leaving unanswered `tool_use` blocks — the Anthropic API
rejects the next request if any `tool_use` lacks a matching `tool_result`,
so we must deliver all answers before the next turn.

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
before ``Tool/execute(_:context:)`` is called. A denied decision becomes a
``ToolResult`` with ``ToolResult/isError`` set — surfaced to the model as
a regular error result so it can adapt, not as an engine-level exception.

### Context growth

The MVP does not auto-compact. A future release will add a context-window
budget to ``QueryContext`` and emit a status event as the conversation
approaches it, prompting the consumer to compact or truncate. For now, consumers that run long sessions should monitor usage
and reset the conversation explicitly.
