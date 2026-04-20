import Foundation

/// Persistence for ``HarnessRun`` entities.
public protocol HarnessRunRepository: Sendable {
    /// Insert a new harness run.
    func create(_ run: HarnessRun) async throws -> HarnessRun

    /// Fetch a run by id.
    func get(id: UUID) async throws -> HarnessRun?

    /// Update an existing run (status, current phase, error message, completion).
    func update(_ run: HarnessRun) async throws

    /// Return the currently-active run on a thread, if any.
    ///
    /// "Active" means status is ``HarnessRunStatus/pending``,
    /// ``HarnessRunStatus/running``, or ``HarnessRunStatus/paused``.
    func activeRun(threadId: UUID) async throws -> HarnessRun?
}
