import Foundation

/// Actor managing the in-memory todo list for a single thread.
///
/// Exposed to the agent through the `write_todos` and `read_todos` built-in
/// tools. When a ``TodoRepository`` is provided, changes are persisted
/// asynchronously on each write.
public actor TodoManager {
    /// Called whenever the todo list is replaced. Use this to emit
    /// ``AgentEvent/todosUpdated(_:)`` to subscribed UIs.
    public typealias ChangeHandler = @Sendable ([TodoItem]) async -> Void

    private var items: [TodoItem]
    private let repository: (any TodoRepository)?
    private let threadId: UUID?
    private let changeHandler: ChangeHandler?

    public init(
        initial: [TodoItem] = [],
        repository: (any TodoRepository)? = nil,
        threadId: UUID? = nil,
        changeHandler: ChangeHandler? = nil
    ) {
        self.items = initial
        self.repository = repository
        self.threadId = threadId
        self.changeHandler = changeHandler
    }

    /// Replace the todo list atomically.
    public func replace(_ newItems: [TodoItem]) async throws {
        items = newItems
        if let repository, let threadId {
            try await repository.replace(threadId: threadId, items: items)
        }
        await changeHandler?(items)
    }

    /// Current todo list.
    public func current() -> [TodoItem] { items }
}
