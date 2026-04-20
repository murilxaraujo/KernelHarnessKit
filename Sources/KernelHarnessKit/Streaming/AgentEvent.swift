import Foundation

/// Every event the engine or harness can emit.
///
/// Events are produced by the agent loop, the harness engine, and the
/// built-in tools. Consumers subscribe via the `AsyncThrowingStream` returned
/// from ``runAgent(context:initialMessages:)`` or ``HarnessEngine/run()`` and
/// encode them into their transport of choice (SSE, WebSocket, JSON log line).
public enum AgentEvent: Sendable, Hashable {
    // MARK: Engine events
    /// A text delta from the model (streamed word-by-word).
    case textChunk(String)
    /// A full turn is complete: the assistant message and its usage.
    case turnComplete(ConversationMessage, UsageSnapshot?)
    /// A tool call has started. `input` is the validated arguments.
    case toolExecutionStarted(name: String, input: [String: JSONValue])
    /// A tool call has finished.
    case toolExecutionCompleted(name: String, result: ToolResult)
    /// A generic status message (e.g., "Retrying in 2s: rate limited").
    case status(String)
    /// An error occurred.
    case error(String)

    // MARK: Coordination events
    /// The agent's state machine changed.
    case statusChange(AgentStatus)
    /// The todo list was replaced.
    case todosUpdated([TodoItem])
    /// A sub-agent started.
    case subAgentStarted(id: String, description: String)
    /// A sub-agent completed with a short summary.
    case subAgentCompleted(id: String, summary: String)

    // MARK: Harness events
    /// A phase started.
    case harnessPhaseStart(name: String, index: Int, total: Int)
    /// A phase completed.
    case harnessPhaseComplete(name: String, summary: String)
    /// A phase errored.
    case harnessPhaseError(name: String, error: String)
    /// The harness completed.
    case harnessComplete
    /// A batch phase began — there are `itemCount` items to process.
    case harnessBatchStart(itemCount: Int)
    /// Progress update inside a batch phase.
    case harnessBatchProgress(current: Int, total: Int)
    /// Human input required — the engine is waiting for the user to respond.
    case harnessHumanInput(question: String)
}
