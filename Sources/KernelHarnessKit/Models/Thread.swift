import Foundation

/// A conversation thread — the top-level unit of a chat session.
public struct Thread: Codable, Sendable, Hashable, Identifiable {
    /// The thread identifier.
    public let id: UUID

    /// The user who owns the thread.
    public let userId: String

    /// A display title. Typically set by the application after the first turn.
    public let title: String?

    /// Thread status.
    public let status: ThreadStatus

    /// Created timestamp.
    public let createdAt: Date

    /// Last-updated timestamp.
    public let updatedAt: Date

    public init(
        id: UUID = UUID(),
        userId: String,
        title: String? = nil,
        status: ThreadStatus = .active,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.userId = userId
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Thread lifecycle status.
public enum ThreadStatus: String, Codable, Sendable, Hashable {
    /// Thread is active and accepting new messages.
    case active
    /// Thread has been archived by the user.
    case archived
    /// Thread has been deleted (soft-delete).
    case deleted
}
