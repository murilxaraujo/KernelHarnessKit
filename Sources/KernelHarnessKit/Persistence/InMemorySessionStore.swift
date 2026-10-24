import Foundation

/// Actor-isolated in-memory implementation of ``SessionStore``.
///
/// This adapter is intended for tests and development. Each operation mutates
/// a copy of the state and publishes it only after the optional commit handler
/// succeeds, which keeps the same all-or-nothing semantics as persistent
/// adapters.
public actor InMemorySessionStore: SessionStore {
    private var state: SessionStoreState
    private let commitHandler: (@Sendable (SessionStoreState) throws -> Void)?

    public init() {
        self.state = SessionStoreState()
        self.commitHandler = nil
    }

    /// Internal initializer used by the file-backed test adapter.
    init(
        initialState: SessionStoreState,
        commitHandler: @escaping @Sendable (SessionStoreState) throws -> Void
    ) {
        self.state = initialState
        self.commitHandler = commitHandler
    }

    private func transact<T>(_ body: (inout SessionStoreState) throws -> T) throws -> T {
        var candidate = state
        let result = try body(&candidate)
        guard candidate != state else { return result }
        try commitHandler?(candidate)
        state = candidate
        return result
    }

    func stateSnapshot() -> SessionStoreState { state }

    public func createProject(_ project: Project) async throws -> Project {
        try transact { state in
            guard state.projects[project.id] == nil else {
                throw SessionStoreError.duplicateID(entity: "project", id: project.id)
            }
            state.projects[project.id] = project
            return project
        }
    }

    public func listProjects() async throws -> [Project] {
        state.projects.values.sorted {
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    public func renameProject(id: UUID, name: String, at date: Date) async throws -> Project {
        try transact { state in
            guard var project = state.projects[id] else {
                throw SessionStoreError.notFound(entity: "project", id: id)
            }
            project.name = name
            project.updatedAt = date
            state.projects[id] = project
            return project
        }
    }

    public func listLocations(projectID: UUID) async throws -> [Location] {
        guard state.projects[projectID] != nil else {
            throw SessionStoreError.notFound(entity: "project", id: projectID)
        }
        return state.locations.values
            .filter { $0.projectID == projectID }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func addLocation(
        projectID: UUID,
        rootURL: URL,
        name: String?,
        id: UUID,
        at date: Date
    ) async throws -> Location {
        let root = try Self.normalizedRoot(rootURL)
        return try transact { state in
            guard state.projects[projectID] != nil else {
                throw SessionStoreError.notFound(entity: "project", id: projectID)
            }
            if let existing = state.locations.values.first(where: {
                $0.projectID == projectID && Self.rootKey($0.rootURL) == Self.rootKey(root)
            }) {
                return existing
            }
            guard state.locations[id] == nil else {
                throw SessionStoreError.duplicateID(entity: "location", id: id)
            }
            let location = Location(
                id: id,
                projectID: projectID,
                rootURL: root,
                name: name,
                createdAt: date,
                updatedAt: date
            )
            state.locations[id] = location
            return location
        }
    }

    public func renameLocation(id: UUID, name: String?, at date: Date) async throws -> Location {
        try transact { state in
            guard var location = state.locations[id] else {
                throw SessionStoreError.notFound(entity: "location", id: id)
            }
            location.name = name
            location.updatedAt = date
            state.locations[id] = location
            return location
        }
    }

    public func updateLocationRoot(id: UUID, rootURL: URL, at date: Date) async throws -> Location {
        let root = try Self.normalizedRoot(rootURL)
        return try transact { state in
            guard var location = state.locations[id] else {
                throw SessionStoreError.notFound(entity: "location", id: id)
            }
            if let collision = state.locations.values.first(where: {
                $0.id != id && $0.projectID == location.projectID
                    && Self.rootKey($0.rootURL) == Self.rootKey(root)
            }) {
                throw SessionStoreError.duplicateRoot(locationID: collision.id)
            }
            location.rootURL = root
            location.updatedAt = date
            state.locations[id] = location
            return location
        }
    }

    public func createSession(_ session: Session) async throws -> Session {
        try transact { state in
            guard state.locations[session.locationID] != nil else {
                throw SessionStoreError.notFound(entity: "location", id: session.locationID)
            }
            guard state.sessions[session.id] == nil else {
                throw SessionStoreError.duplicateID(entity: "session", id: session.id)
            }
            state.sessions[session.id] = session
            state.nextMessageSequence[session.id] = 0
            return session
        }
    }

    public func loadSnapshot(sessionID: UUID) async throws -> SessionSnapshot? {
        guard let session = state.sessions[sessionID] else { return nil }
        let messages = state.messages.values
            .filter { $0.sessionID == sessionID }
            .sorted { $0.sequence < $1.sequence }
        let runs = state.runs.values
            .filter { $0.sessionID == sessionID }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt < $1.startedAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        let latestRun = runs.last
        let activeRun = runs.last(where: { !$0.status.isTerminal })
        let runIDs = Set(runs.map(\.id))
        let calls = state.toolCalls.values
            .filter { runIDs.contains($0.runID) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                if $0.ordinal != $1.ordinal { return $0.ordinal < $1.ordinal }
                return $0.id.uuidString < $1.id.uuidString
            }
        let pendingRequests = state.permissionRequests.values
            .filter { runIDs.contains($0.runID) && $0.status == .pending }
            .sorted { $0.createdAt < $1.createdAt }
        return SessionSnapshot(
            session: session,
            messages: messages,
            latestRun: latestRun,
            activeRun: activeRun,
            toolCalls: calls,
            pendingPermissionRequests: pendingRequests
        )
    }

    public func listSessions(locationID: UUID) async throws -> [SessionSummary] {
        guard state.locations[locationID] != nil else {
            throw SessionStoreError.notFound(entity: "location", id: locationID)
        }
        return state.sessions.values
            .filter { $0.locationID == locationID }
            .map { session in
                let latest = state.messages.values
                    .filter { $0.sessionID == session.id }
                    .max { $0.sequence < $1.sequence }
                return SessionSummary(session: session, latestMessage: latest)
            }
            .sorted {
                if $0.session.updatedAt != $1.session.updatedAt {
                    return $0.session.updatedAt > $1.session.updatedAt
                }
                return $0.id.uuidString < $1.id.uuidString
            }
    }

    public func archiveSession(id: UUID, at date: Date) async throws {
        try transact { state in
            guard var session = state.sessions[id] else {
                throw SessionStoreError.notFound(entity: "session", id: id)
            }
            if let run = state.runs.values.first(where: {
                $0.sessionID == id && !$0.status.isTerminal
            }) {
                throw SessionStoreError.invalidTransition(entity: "session", id: id, state: "active run \(run.id)")
            }
            session.status = .archived
            session.updatedAt = date
            state.sessions[id] = session
        }
    }

    public func setDefaultModel(_ model: ModelRef, sessionID: UUID, at date: Date) async throws {
        try transact { state in
            guard var session = state.sessions[sessionID] else {
                throw SessionStoreError.notFound(entity: "session", id: sessionID)
            }
            session.defaultModel = model
            session.updatedAt = date
            state.sessions[sessionID] = session
        }
    }

    public func beginTurn(
        sessionID: UUID,
        text: String,
        runID: UUID,
        userMessageID: UUID,
        at date: Date
    ) async throws -> TurnAdmissionResult {
        guard let session = state.sessions[sessionID] else {
            throw SessionStoreError.notFound(entity: "session", id: sessionID)
        }
        guard session.status == .active else {
            throw SessionStoreError.sessionArchived(sessionID)
        }
        if let existing = state.runs.values.first(where: {
            $0.sessionID == sessionID && !$0.status.isTerminal
        }) {
            return .busy(activeRunID: existing.id)
        }
        return try transact { state in
            guard let session = state.sessions[sessionID] else {
                throw SessionStoreError.notFound(entity: "session", id: sessionID)
            }
            guard session.status == .active else {
                throw SessionStoreError.sessionArchived(sessionID)
            }
            guard state.runs[runID] == nil else {
                throw SessionStoreError.duplicateID(entity: "run", id: runID)
            }
            guard state.messages[userMessageID] == nil else {
                throw SessionStoreError.duplicateID(entity: "message", id: userMessageID)
            }
            let sequence = Self.allocateSequence(sessionID, in: &state)
            let message = SessionMessage(
                id: userMessageID,
                sessionID: sessionID,
                runID: runID,
                sequence: sequence,
                role: .user,
                content: [.text(text)],
                status: .complete,
                createdAt: date,
                updatedAt: date
            )
            let run = SessionRun(
                id: runID,
                sessionID: sessionID,
                userMessageID: userMessageID,
                model: session.defaultModel,
                status: .running,
                startedAt: date
            )
            var updatedSession = session
            updatedSession.updatedAt = date
            state.messages[userMessageID] = message
            state.runs[runID] = run
            state.sessions[sessionID] = updatedSession
            return TurnAdmissionResult.accepted(run: run, userMessage: message)
        }
    }

    public func startAssistantMessage(
        sessionID: UUID,
        runID: UUID,
        messageID: UUID,
        initialText: String,
        at date: Date
    ) async throws -> SessionMessage {
        try transact { state in
            guard let run = state.runs[runID], run.sessionID == sessionID else {
                throw SessionStoreError.notFound(entity: "run", id: runID)
            }
            guard run.status == .running else {
                throw SessionStoreError.invalidTransition(entity: "run", id: runID, state: run.status.rawValue)
            }
            guard !initialText.isEmpty else {
                throw SessionStoreError.invalidTransition(entity: "message", id: messageID, state: "empty assistant text")
            }
            guard state.messages[messageID] == nil else {
                throw SessionStoreError.duplicateID(entity: "message", id: messageID)
            }
            let message = SessionMessage(
                id: messageID,
                sessionID: sessionID,
                runID: runID,
                sequence: Self.allocateSequence(sessionID, in: &state),
                role: .assistant,
                content: [.text(initialText)],
                status: .inProgress,
                checkpointRevision: 1,
                createdAt: date,
                updatedAt: date
            )
            state.messages[messageID] = message
            return message
        }
    }

    public func checkpointAssistantText(
        messageID: UUID,
        revision: Int64,
        accumulatedText: String,
        at date: Date
    ) async throws -> SessionMessage {
        try transact { state in
            try Self.applyCheckpoint(
                AssistantTextCheckpoint(
                    messageID: messageID,
                    revision: revision,
                    accumulatedText: accumulatedText
                ),
                in: &state,
                at: date
            )
        }
    }

    public func persistAssistantToolCalls(
        sessionID: UUID,
        runID: UUID,
        messageID: UUID,
        content: [SessionContentPart],
        calls: [SessionToolCall],
        at date: Date
    ) async throws -> SessionMessage {
        try transact { state in
            guard let run = state.runs[runID], run.sessionID == sessionID, run.status == .running else {
                throw SessionStoreError.notFound(entity: "active run", id: runID)
            }
            guard !calls.isEmpty else {
                throw SessionStoreError.invalidTransition(entity: "tool calls", id: messageID, state: "empty batch")
            }
            let existingMessage = state.messages[messageID]
            if let existingMessage {
                guard existingMessage.sessionID == sessionID,
                      existingMessage.runID == runID,
                      existingMessage.role == .assistant,
                      existingMessage.status == .inProgress else {
                    throw SessionStoreError.duplicateID(entity: "message", id: messageID)
                }
            }
            var toolCallIDs = Set<UUID>()
            var ordinals = Set<Int>()
            for call in calls {
                guard call.runID == runID, call.messageID == messageID,
                      toolCallIDs.insert(call.id).inserted,
                      ordinals.insert(call.ordinal).inserted,
                      state.toolCalls[call.id] == nil else {
                    throw SessionStoreError.invalidTransition(entity: "tool call", id: call.id, state: "invalid intent batch")
                }
            }
            var parts = content
            for call in calls.sorted(by: { $0.ordinal < $1.ordinal }) where !parts.contains(.toolCall(call.id)) {
                parts.append(.toolCall(call.id))
            }
            let message: SessionMessage
            if var existingMessage {
                existingMessage.content = parts
                existingMessage.status = .complete
                existingMessage.updatedAt = date
                message = existingMessage
            } else {
                message = SessionMessage(
                    id: messageID,
                    sessionID: sessionID,
                    runID: runID,
                    sequence: Self.allocateSequence(sessionID, in: &state),
                    role: .assistant,
                    content: parts,
                    status: .complete,
                    createdAt: date,
                    updatedAt: date
                )
            }
            state.messages[messageID] = message
            for var call in calls.sorted(by: { $0.ordinal < $1.ordinal }) {
                call.status = .pending
                call.executionDisposition = .notStarted
                call.resultMessageSequence = Self.allocateSequence(sessionID, in: &state)
                call.updatedAt = date
                state.toolCalls[call.id] = call
            }
            return message
        }
    }

    public func requestPermission(_ request: SessionPermissionRequest, at date: Date) async throws {
        try transact { state in
            guard var run = state.runs[request.runID], !run.status.isTerminal else {
                throw SessionStoreError.notFound(entity: "active run", id: request.runID)
            }
            guard var call = state.toolCalls[request.toolCallID], call.runID == request.runID else {
                throw SessionStoreError.notFound(entity: "tool call", id: request.toolCallID)
            }
            guard request.toolName == call.name, request.input == call.input else {
                throw SessionStoreError.invalidTransition(entity: "permission request", id: request.id, state: "does not match tool call")
            }
            guard call.status == .pending, call.permissionRequestID == nil else {
                throw SessionStoreError.invalidTransition(entity: "tool call", id: call.id, state: call.status.rawValue)
            }
            guard state.permissionRequests[request.id] == nil else {
                throw SessionStoreError.duplicateID(entity: "permission request", id: request.id)
            }
            guard request.status == .pending else {
                throw SessionStoreError.invalidTransition(entity: "permission request", id: request.id, state: request.status.rawValue)
            }
            call.status = .awaitingApproval
            call.permissionRequestID = request.id
            call.updatedAt = date
            run.status = .awaitingApproval
            state.toolCalls[call.id] = call
            state.permissionRequests[request.id] = request
            state.runs[run.id] = run
        }
    }

    public func resolvePermission(
        requestID: UUID,
        decision: PermissionResolution,
        deniedResultMessageID: UUID,
        at date: Date
    ) async throws -> PermissionUpdateResult {
        try transact { state in
            guard var request = state.permissionRequests[requestID] else {
                throw SessionStoreError.notFound(entity: "permission request", id: requestID)
            }
            guard var call = state.toolCalls[request.toolCallID] else {
                throw SessionStoreError.notFound(entity: "tool call", id: request.toolCallID)
            }
            guard var run = state.runs[request.runID] else {
                throw SessionStoreError.notFound(entity: "run", id: request.runID)
            }
            if request.status != .pending {
                if Self.matches(decision, status: request.status) {
                    let message = state.messages.values.first(where: {
                        $0.runID == run.id && $0.role == .tool && $0.content.contains(.toolResult(call.id))
                    })
                    return PermissionUpdateResult(request: request, toolCall: call, toolResultMessage: message)
                }
                if request.status == .cancelled {
                    throw SessionStoreError.alreadyResolved(requestID: requestID)
                }
                throw SessionStoreError.conflictingPermissionDecision(requestID: requestID)
            }
            guard !run.status.isTerminal, call.status == .awaitingApproval else {
                throw SessionStoreError.invalidTransition(entity: "permission request", id: requestID, state: request.status.rawValue)
            }

            var resultMessage: SessionMessage?
            switch decision {
            case .allow:
                request.status = .allowed
                request.resolutionReason = nil
            case .deny(let reason):
                request.status = .denied
                request.resolutionReason = reason
                call.status = .denied
                call.result = .failure(reason ?? "Permission denied", kind: .permissionDenied)
                call.executionDisposition = .notStarted
                resultMessage = try Self.makeToolResultMessage(
                    id: deniedResultMessageID,
                    call: call,
                    state: &state,
                    at: date
                )
            }
            request.resolvedAt = date
            call.updatedAt = date
            if !state.permissionRequests.values.contains(where: {
                $0.runID == run.id && $0.id != requestID && $0.status == .pending
            }) {
                run.status = .running
            }
            state.permissionRequests[requestID] = request
            state.toolCalls[call.id] = call
            state.runs[run.id] = run
            return PermissionUpdateResult(request: request, toolCall: call, toolResultMessage: resultMessage)
        }
    }

    public func markToolCallRunning(id: UUID, at date: Date) async throws -> SessionToolCall {
        try transact { state in
            guard var call = state.toolCalls[id] else {
                throw SessionStoreError.notFound(entity: "tool call", id: id)
            }
            guard let run = state.runs[call.runID], !run.status.isTerminal else {
                throw SessionStoreError.invalidTransition(entity: "run", id: call.runID, state: "terminal or missing")
            }
            switch call.status {
            case .pending:
                guard call.permissionRequestID == nil else {
                    throw SessionStoreError.invalidTransition(entity: "tool call", id: id, state: call.status.rawValue)
                }
            case .awaitingApproval:
                guard let requestID = call.permissionRequestID,
                      state.permissionRequests[requestID]?.status == .allowed else {
                    throw SessionStoreError.invalidTransition(entity: "tool call", id: id, state: "approval not granted")
                }
            default:
                throw SessionStoreError.invalidTransition(entity: "tool call", id: id, state: call.status.rawValue)
            }
            call.status = .running
            call.executionDisposition = .mayHaveExecuted
            call.updatedAt = date
            state.toolCalls[id] = call
            return call
        }
    }

    public func denyToolCall(
        id: UUID,
        result: ToolResult,
        resultMessageID: UUID,
        at date: Date
    ) async throws -> (SessionToolCall, SessionMessage) {
        try transact { state in
            guard var call = state.toolCalls[id] else {
                throw SessionStoreError.notFound(entity: "tool call", id: id)
            }
            guard let run = state.runs[call.runID], !run.status.isTerminal else {
                throw SessionStoreError.invalidTransition(entity: "run", id: call.runID, state: "terminal or missing")
            }
            guard call.status == .pending, call.permissionRequestID == nil else {
                throw SessionStoreError.invalidTransition(entity: "tool call", id: id, state: call.status.rawValue)
            }
            call.status = .denied
            call.result = result
            call.executionDisposition = .notStarted
            call.updatedAt = date
            let message = try Self.makeToolResultMessage(id: resultMessageID, call: call, state: &state, at: date)
            state.toolCalls[id] = call
            return (call, message)
        }
    }

    public func completeToolCall(
        id: UUID,
        result: ToolResult,
        resultMessageID: UUID,
        at date: Date
    ) async throws -> (SessionToolCall, SessionMessage) {
        try transact { state in
            guard var call = state.toolCalls[id] else {
                throw SessionStoreError.notFound(entity: "tool call", id: id)
            }
            guard let run = state.runs[call.runID], !run.status.isTerminal else {
                throw SessionStoreError.invalidTransition(entity: "run", id: call.runID, state: "terminal or missing")
            }
            guard call.status == .running else {
                throw SessionStoreError.invalidTransition(entity: "tool call", id: id, state: call.status.rawValue)
            }
            call.result = result
            call.status = result.isError ? .failed : .succeeded
            call.updatedAt = date
            let message = try Self.makeToolResultMessage(id: resultMessageID, call: call, state: &state, at: date)
            state.toolCalls[id] = call
            return (call, message)
        }
    }

    public func finishRun(
        id: UUID,
        outcome: SessionRunOutcome,
        finalAssistantCheckpoints: [AssistantTextCheckpoint],
        at date: Date
    ) async throws -> SessionRun {
        try transact { state in
            try Self.finishRun(
                id: id,
                outcome: outcome,
                finalAssistantCheckpoints: finalAssistantCheckpoints,
                state: &state,
                at: date
            )
        }
    }

    public func recoverRun(id: UUID, at date: Date) async throws -> SessionRun {
        try transact { state in
            try Self.finishRun(
                id: id,
                outcome: .interrupted,
                finalAssistantCheckpoints: [],
                state: &state,
                at: date
            )
        }
    }

    private static func applyCheckpoint(
        _ checkpoint: AssistantTextCheckpoint,
        in state: inout SessionStoreState,
        at date: Date
    ) throws -> SessionMessage {
        guard var message = state.messages[checkpoint.messageID] else {
            throw SessionStoreError.notFound(entity: "message", id: checkpoint.messageID)
        }
        guard message.role == .assistant, message.status == .inProgress else {
            throw SessionStoreError.invalidTransition(
                entity: "message",
                id: checkpoint.messageID,
                state: message.status.rawValue
            )
        }
        if checkpoint.revision < message.checkpointRevision { return message }
        if checkpoint.revision == message.checkpointRevision {
            let currentText = message.content.compactMap { part -> String? in
                if case .text(let text) = part { return text }
                return nil
            }.joined()
            guard currentText == checkpoint.accumulatedText else {
                throw SessionStoreError.staleCheckpoint(
                    messageID: checkpoint.messageID,
                    currentRevision: message.checkpointRevision
                )
            }
            return message
        }
        if let textIndex = message.content.firstIndex(where: {
            if case .text = $0 { return true }
            return false
        }) {
            message.content[textIndex] = .text(checkpoint.accumulatedText)
        } else if !checkpoint.accumulatedText.isEmpty {
            message.content.insert(.text(checkpoint.accumulatedText), at: 0)
        }
        message.checkpointRevision = checkpoint.revision
        message.updatedAt = date
        state.messages[message.id] = message
        return message
    }

    private static func finishRun(
        id: UUID,
        outcome: SessionRunOutcome,
        finalAssistantCheckpoints: [AssistantTextCheckpoint],
        state: inout SessionStoreState,
        at date: Date
    ) throws -> SessionRun {
        guard var run = state.runs[id] else {
            throw SessionStoreError.notFound(entity: "run", id: id)
        }
        if run.status.isTerminal {
            guard run.status == outcome.status else {
                throw SessionStoreError.invalidTransition(entity: "run", id: id, state: run.status.rawValue)
            }
            return run
        }
        for checkpoint in finalAssistantCheckpoints {
            guard state.messages[checkpoint.messageID]?.runID == id else {
                throw SessionStoreError.invalidTransition(
                    entity: "message",
                    id: checkpoint.messageID,
                    state: "not in run"
                )
            }
            _ = try applyCheckpoint(checkpoint, in: &state, at: date)
        }
        let calls = state.toolCalls.values.filter { $0.runID == id }
        if case .completed = outcome, calls.contains(where: {
            ![.succeeded, .failed, .denied].contains($0.status)
        }) {
            throw SessionStoreError.invalidTransition(entity: "run", id: id, state: "unfinished tool calls")
        }
        for requestID in Array(state.permissionRequests.keys) {
            guard var request = state.permissionRequests[requestID],
                  request.runID == id, request.status == .pending else { continue }
            request.status = .cancelled
            request.resolvedAt = date
            state.permissionRequests[requestID] = request
        }
        for callID in Array(state.toolCalls.keys) {
            guard var call = state.toolCalls[callID], call.runID == id, !call.status.isTerminal else { continue }
            if call.status == .running { call.executionDisposition = .mayHaveExecuted }
            else { call.executionDisposition = .notStarted }
            call.status = .interrupted
            call.updatedAt = date
            state.toolCalls[callID] = call
        }
        for messageID in Array(state.messages.keys) {
            guard var message = state.messages[messageID],
                  message.runID == id, message.status == .inProgress else { continue }
            switch outcome {
            case .completed: message.status = .complete
            case .failed: message.status = .failed
            case .cancelled, .interrupted: message.status = .interrupted
            }
            message.updatedAt = date
            state.messages[messageID] = message
        }
        run.status = outcome.status
        if case .failed(let failure) = outcome { run.failure = failure }
        run.completedAt = date
        state.runs[id] = run
        if var session = state.sessions[run.sessionID] {
            session.updatedAt = date
            state.sessions[run.sessionID] = session
        }
        return run
    }

    private static func makeToolResultMessage(
        id: UUID,
        call: SessionToolCall,
        state: inout SessionStoreState,
        at date: Date
    ) throws -> SessionMessage {
        if let existing = state.messages[id] {
            guard existing.role == .tool, existing.runID == call.runID,
                  existing.content == [.toolResult(call.id)] else {
                throw SessionStoreError.duplicateID(entity: "message", id: id)
            }
            return existing
        }
        guard let run = state.runs[call.runID] else {
            throw SessionStoreError.notFound(entity: "run", id: call.runID)
        }
        let sequence: Int64
        if let reservedSequence = call.resultMessageSequence {
            sequence = reservedSequence
        } else {
            sequence = allocateSequence(run.sessionID, in: &state)
        }
        let message = SessionMessage(
            id: id,
            sessionID: run.sessionID,
            runID: call.runID,
            sequence: sequence,
            role: .tool,
            content: [.toolResult(call.id)],
            status: .complete,
            createdAt: date,
            updatedAt: date
        )
        state.messages[id] = message
        return message
    }

    private static func allocateSequence(_ sessionID: UUID, in state: inout SessionStoreState) -> Int64 {
        let sequence = state.nextMessageSequence[sessionID, default: 0]
        state.nextMessageSequence[sessionID] = sequence + 1
        return sequence
    }

    private static func normalizedRoot(_ url: URL) throws -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw SessionStoreError.invalidRootURL }
        return url.standardizedFileURL
    }

    private static func rootKey(_ url: URL) -> String { url.standardizedFileURL.path }

    private static func matches(_ decision: PermissionResolution, status: PermissionRequestStatus) -> Bool {
        switch (decision, status) {
        case (.allow, .allowed), (.deny, .denied): true
        default: false
        }
    }
}

struct SessionStoreState: Codable, Sendable, Equatable {
    var projects: [UUID: Project] = [:]
    var locations: [UUID: Location] = [:]
    var sessions: [UUID: Session] = [:]
    var messages: [UUID: SessionMessage] = [:]
    var runs: [UUID: SessionRun] = [:]
    var toolCalls: [UUID: SessionToolCall] = [:]
    var permissionRequests: [UUID: SessionPermissionRequest] = [:]
    var nextMessageSequence: [UUID: Int64] = [:]
}
