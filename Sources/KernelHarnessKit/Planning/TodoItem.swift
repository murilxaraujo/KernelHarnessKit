import Foundation

/// A single item on the agent's plan.
public struct TodoItem: Codable, Sendable, Hashable {
    /// Human-readable description of the item.
    public let content: String

    /// Current progress state.
    public let status: TodoStatus

    public init(content: String, status: TodoStatus = .pending) {
        self.content = content
        self.status = status
    }
}

/// Lifecycle state of a ``TodoItem``.
public enum TodoStatus: String, Codable, Sendable, Hashable {
    /// Not started yet.
    case pending
    /// Currently being worked on. At most one item should be in-progress.
    case inProgress = "in_progress"
    /// Finished.
    case completed
}
