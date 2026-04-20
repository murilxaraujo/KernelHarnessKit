import Foundation

/// High-level state of an agent session.
public enum AgentStatus: String, Codable, Sendable, Hashable {
    /// Not running yet.
    case idle
    /// Actively processing a turn.
    case working
    /// Waiting for the user to respond to an `ask_user` question.
    case waitingForUser = "waiting_for_user"
    /// Finished successfully.
    case complete
    /// Finished with an error.
    case error
    /// Cancelled externally.
    case cancelled
}
