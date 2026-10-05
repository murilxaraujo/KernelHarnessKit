import Foundation

/// Errors produced by the agent loop and engine.
public enum AgentError: Error, Sendable, Equatable, LocalizedError {
    /// The Foundation Models session finished without producing a final message.
    case noFinalMessage

    /// The loop exceeded its ``QueryContext/maxTurns`` budget.
    case maxTurnsExceeded(Int)

    /// Wrap any other error raised inside the loop.
    case underlying(String)

    public var errorDescription: String? {
        switch self {
        case .noFinalMessage:
            return "Foundation Models finished without a final message."
        case .maxTurnsExceeded(let n):
            return "Agent loop exceeded maxTurns (\(n))."
        case .underlying(let detail):
            return "Underlying error: \(detail)."
        }
    }
}
