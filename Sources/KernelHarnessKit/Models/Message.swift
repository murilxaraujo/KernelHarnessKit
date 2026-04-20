import Foundation

/// A persisted message in a thread.
///
/// Distinct from ``ConversationMessage`` — ``Message`` carries database metadata
/// (id, threadId, timestamp, token usage), while ``ConversationMessage`` is the
/// stripped-down wire format consumed by the LLM.
public struct Message: Codable, Sendable, Hashable, Identifiable {
    /// Unique message id.
    public let id: UUID

    /// The thread this message belongs to.
    public let threadId: UUID

    /// The author role (user, assistant, tool, system).
    public let role: Role

    /// The ordered content blocks.
    public let content: [ContentBlock]

    /// Tokens consumed to generate this message, if any.
    public let usage: UsageSnapshot?

    /// Creation timestamp.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        threadId: UUID,
        role: Role,
        content: [ContentBlock],
        usage: UsageSnapshot? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadId = threadId
        self.role = role
        self.content = content
        self.usage = usage
        self.createdAt = createdAt
    }

    /// Project down to the wire-format ``ConversationMessage``.
    public var conversationMessage: ConversationMessage {
        ConversationMessage(role: role, content: content)
    }
}
