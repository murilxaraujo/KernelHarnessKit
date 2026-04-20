import Foundation

/// Persistence for ``Thread`` entities.
///
/// Implementations are consumer-provided; KernelHarnessPostgres ships a
/// PostgresNIO-backed implementation for the common case.
public protocol ThreadRepository: Sendable {
    /// Insert a new thread. Returns the stored thread (may differ from the
    /// input if the repository mutates ids or timestamps).
    func create(_ thread: Thread) async throws -> Thread

    /// Fetch a thread by id.
    func get(id: UUID) async throws -> Thread?

    /// List threads for a user, optionally filtered by status.
    func list(userId: String, status: ThreadStatus?) async throws -> [Thread]

    /// Update an existing thread.
    func update(_ thread: Thread) async throws

    /// Delete a thread by id. No-op if no thread with that id exists.
    func delete(id: UUID) async throws
}
