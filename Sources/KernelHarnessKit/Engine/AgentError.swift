import Foundation

/// Errors produced by the agent loop and engine.
public enum AgentError: Error, Sendable, Equatable, LocalizedError {
    /// The provider finished the turn without producing a final message.
    case noFinalMessage

    /// The loop exceeded its ``QueryContext/maxTurns`` budget.
    case maxTurnsExceeded(Int)

    /// The model requested a tool that isn't registered.
    case unknownTool(String)

    /// A permission check denied a tool invocation.
    case permissionDenied(String)

    /// The context exceeded the model's window and no compaction strategy is
    /// configured.
    case contextTooLong

    /// The provider surfaced a transport or parsing error that should stop
    /// the loop.
    case provider(String)

    /// Wrap any other error raised inside the loop.
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .noFinalMessage:
            return "Provider finished without a final message."
        case .maxTurnsExceeded(let n):
            return "Agent loop exceeded maxTurns (\(n))."
        case .unknownTool(let name):
            return "Model requested unknown tool '\(name)'."
        case .permissionDenied(let reason):
            return "Permission denied: \(reason)."
        case .contextTooLong:
            return "Conversation exceeds the model's context window."
        case .provider(let detail):
            return "Provider error: \(detail)."
        case .underlying(let detail):
            return "Underlying error: \(detail)."
        }
    }
}
