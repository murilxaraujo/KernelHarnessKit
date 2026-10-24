import Foundation

/// Outcome of the store's atomic turn-admission operation.
public enum TurnAdmissionResult: Sendable, Hashable {
    case accepted(run: SessionRun, userMessage: SessionMessage)
    case busy(activeRunID: UUID)
}

/// Result of atomically resolving a permission request.
public struct PermissionUpdateResult: Sendable, Hashable {
    public let request: SessionPermissionRequest
    public let toolCall: SessionToolCall
    /// Present when a denial created its durable tool-result message.
    public let toolResultMessage: SessionMessage?

    public init(
        request: SessionPermissionRequest,
        toolCall: SessionToolCall,
        toolResultMessage: SessionMessage?
    ) {
        self.request = request
        self.toolCall = toolCall
        self.toolResultMessage = toolResultMessage
    }
}

/// Errors returned by the atomic session store.
public enum SessionStoreError: Error, Sendable, Hashable {
    case notFound(entity: String, id: UUID)
    case invalidRootURL
    case duplicateRoot(locationID: UUID)
    case duplicateID(entity: String, id: UUID)
    case sessionArchived(UUID)
    case invalidTransition(entity: String, id: UUID, state: String)
    case staleCheckpoint(messageID: UUID, currentRevision: Int64)
    case alreadyResolved(requestID: UUID)
    case conflictingPermissionDecision(requestID: UUID)
}

/// Persistence boundary used by the durable session coordinator.
///
/// Mutating methods are domain transactions. Implementations must make each
/// method atomic against all other writers to the same backing store. In
/// particular, `beginTurn` owns the one-active-Run-per-Session invariant.
/// Existing per-entity repositories remain available to existing consumers;
/// the coordinator must not compose their independent writes as a transaction.
public protocol SessionStore: Sendable {
    func createProject(_ project: Project) async throws -> Project
    func listProjects() async throws -> [Project]
    func renameProject(id: UUID, name: String, at date: Date) async throws -> Project

    func listLocations(projectID: UUID) async throws -> [Location]
    func addLocation(
        projectID: UUID,
        rootURL: URL,
        name: String?,
        id: UUID,
        at date: Date
    ) async throws -> Location
    func renameLocation(id: UUID, name: String?, at date: Date) async throws -> Location
    func updateLocationRoot(id: UUID, rootURL: URL, at date: Date) async throws -> Location

    func createSession(_ session: Session) async throws -> Session
    func loadSnapshot(sessionID: UUID) async throws -> SessionSnapshot?
    func listSessions(locationID: UUID) async throws -> [SessionSummary]
    func archiveSession(id: UUID, at date: Date) async throws
    func setDefaultModel(_ model: ModelRef, sessionID: UUID, at date: Date) async throws

    /// Atomically inserts the user message and Run, capturing the Session's
    /// current default model. A busy result must not mutate any records.
    func beginTurn(
        sessionID: UUID,
        text: String,
        runID: UUID,
        userMessageID: UUID,
        at date: Date
    ) async throws -> TurnAdmissionResult
    func startAssistantMessage(
        sessionID: UUID,
        runID: UUID,
        messageID: UUID,
        initialText: String,
        at date: Date
    ) async throws -> SessionMessage
    func checkpointAssistantText(
        messageID: UUID,
        revision: Int64,
        accumulatedText: String,
        at date: Date
    ) async throws -> SessionMessage
    /// Atomically stores the assistant response and all tool-call intents,
    /// reserving result-message order before any tool can run.
    func persistAssistantToolCalls(
        sessionID: UUID,
        runID: UUID,
        messageID: UUID,
        content: [SessionContentPart],
        calls: [SessionToolCall],
        at date: Date
    ) async throws -> SessionMessage
    /// Persists a pending approval request and moves the linked Run to
    /// `awaitingApproval` in the same transaction.
    func requestPermission(_ request: SessionPermissionRequest, at date: Date) async throws
    /// Resolves a request with compare-and-set semantics. A denial also commits
    /// its tool result; an allow does not start the tool.
    func resolvePermission(
        requestID: UUID,
        decision: PermissionResolution,
        deniedResultMessageID: UUID,
        at date: Date
    ) async throws -> PermissionUpdateResult
    /// Persists the `running` state before the caller invokes a tool side effect.
    func markToolCallRunning(id: UUID, at date: Date) async throws -> SessionToolCall
    /// Records a direct policy denial without creating an approval request.
    func denyToolCall(
        id: UUID,
        result: ToolResult,
        resultMessageID: UUID,
        at date: Date
    ) async throws -> (SessionToolCall, SessionMessage)
    /// Persists a tool outcome and its ordered result message atomically.
    func completeToolCall(
        id: UUID,
        result: ToolResult,
        resultMessageID: UUID,
        at date: Date
    ) async throws -> (SessionToolCall, SessionMessage)
    /// Commits final text checkpoints and terminal Run/message state together.
    /// For cancellation, the caller must stop or join executing tasks first.
    func finishRun(
        id: UUID,
        outcome: SessionRunOutcome,
        finalAssistantCheckpoints: [AssistantTextCheckpoint],
        at date: Date
    ) async throws -> SessionRun
    /// Repairs one Run only after its prior executor is known to be gone.
    /// Never call this for a Run that may still be executing elsewhere.
    func recoverRun(id: UUID, at date: Date) async throws -> SessionRun
}
