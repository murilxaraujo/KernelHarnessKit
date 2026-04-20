import Foundation

/// Persistence for ``Message`` entities.
public protocol MessageRepository: Sendable {
    /// Append a message to a thread.
    func append(_ message: Message, threadId: UUID) async throws

    /// List all messages in a thread, oldest first.
    func list(threadId: UUID) async throws -> [Message]

    /// Delete every message in a thread.
    func deleteAll(threadId: UUID) async throws
}
