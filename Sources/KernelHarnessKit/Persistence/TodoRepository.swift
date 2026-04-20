import Foundation

/// Persistence for the per-thread todo list.
public protocol TodoRepository: Sendable {
    /// Fetch the current todo list for a thread.
    func get(threadId: UUID) async throws -> [TodoItem]

    /// Replace the todo list atomically.
    func replace(threadId: UUID, items: [TodoItem]) async throws
}
