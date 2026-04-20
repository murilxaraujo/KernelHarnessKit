import Foundation

/// A run of a harness workflow associated with a thread.
public struct HarnessRun: Codable, Sendable, Hashable, Identifiable {
    /// Unique run id.
    public let id: UUID

    /// The thread this run belongs to.
    public let threadId: UUID

    /// The harness type (e.g., `"case_research"`).
    public let harnessType: String

    /// Current lifecycle status.
    public let status: HarnessRunStatus

    /// Index of the currently executing phase (0-based). `nil` before start.
    public let currentPhaseIndex: Int?

    /// Error message, if the run failed.
    public let errorMessage: String?

    /// Start timestamp.
    public let startedAt: Date

    /// Completion timestamp (nil if still running).
    public let completedAt: Date?

    public init(
        id: UUID = UUID(),
        threadId: UUID,
        harnessType: String,
        status: HarnessRunStatus = .pending,
        currentPhaseIndex: Int? = nil,
        errorMessage: String? = nil,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.threadId = threadId
        self.harnessType = harnessType
        self.status = status
        self.currentPhaseIndex = currentPhaseIndex
        self.errorMessage = errorMessage
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

/// Lifecycle state of a ``HarnessRun``.
public enum HarnessRunStatus: String, Codable, Sendable, Hashable {
    /// Harness is registered but hasn't started executing.
    case pending
    /// Harness is actively executing a phase.
    case running
    /// Harness is paused waiting for user input.
    case paused
    /// All phases completed successfully.
    case completed
    /// A phase raised an error; the run stopped.
    case failed
    /// The run was cancelled externally.
    case cancelled
}
