import Foundation
import Testing
@testable import KernelHarnessKit

@Suite("SessionStore")
struct SessionStoreTests {
    @Test func duplicateLocationsReturnExistingAndRootMoveRejectsCollision() async throws {
        let store = InMemorySessionStore()
        let project = try await store.createProject(Project(name: "Kernel"))
        let first = try await store.addLocation(
            projectID: project.id,
            rootURL: URL(fileURLWithPath: "/workspace/../workspace/app"),
            name: "App",
            id: UUID(),
            at: .now
        )
        let duplicate = try await store.addLocation(
            projectID: project.id,
            rootURL: URL(fileURLWithPath: "/workspace/app"),
            name: "Duplicate",
            id: UUID(),
            at: .now
        )
        #expect(first.id == duplicate.id)
        #expect(try await store.listLocations(projectID: project.id).count == 1)

        let otherProject = try await store.createProject(Project(name: "Independent"))
        let independentRoot = try await store.addLocation(
            projectID: otherProject.id,
            rootURL: URL(fileURLWithPath: "/workspace/app"),
            name: nil,
            id: UUID(),
            at: .now
        )
        #expect(independentRoot.id != first.id)

        let second = try await store.addLocation(
            projectID: project.id,
            rootURL: URL(fileURLWithPath: "/workspace/other"),
            name: nil,
            id: UUID(),
            at: .now
        )
        await #expect(throws: SessionStoreError.self) {
            try await store.updateLocationRoot(id: second.id, rootURL: first.rootURL, at: .now)
        }
    }

    @Test func concurrentTurnAdmissionCreatesOnlyOneRunAndUserMessage() async throws {
        let (store, session) = try await makeSession()
        let proposals = (0..<12).map { _ in (UUID(), UUID()) }
        let results = await withTaskGroup(of: TurnAdmissionResult?.self, returning: [TurnAdmissionResult].self) { group in
            for (runID, messageID) in proposals {
                group.addTask {
                    try? await store.beginTurn(
                        sessionID: session.id,
                        text: "hello",
                        runID: runID,
                        userMessageID: messageID,
                        at: .now
                    )
                }
            }
            var values: [TurnAdmissionResult] = []
            for await result in group {
                if let result { values.append(result) }
            }
            return values
        }

        #expect(results.count == proposals.count)
        #expect(results.filter { if case .accepted = $0 { true } else { false } }.count == 1)
        #expect(results.filter { if case .busy = $0 { true } else { false } }.count == proposals.count - 1)
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(snapshot.messages.count == 1)
        #expect(snapshot.activeRun != nil)
    }

    @Test func checkpointsAreMonotonicAndIdempotent() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "prompt", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let assistant = try await store.startAssistantMessage(
            sessionID: session.id,
            runID: run.id,
            messageID: UUID(),
            initialText: "Hello",
            at: .now
        )
        let same = try await store.checkpointAssistantText(
            messageID: assistant.id,
            revision: 1,
            accumulatedText: "Hello",
            at: .now
        )
        let newer = try await store.checkpointAssistantText(
            messageID: assistant.id,
            revision: 2,
            accumulatedText: "Hello, world",
            at: .now
        )
        let delayed = try await store.checkpointAssistantText(
            messageID: assistant.id,
            revision: 1,
            accumulatedText: "Hello",
            at: .now
        )
        #expect(same.content == [.text("Hello")])
        #expect(newer.content == [.text("Hello, world")])
        #expect(delayed.content == newer.content)
        #expect(delayed.checkpointRevision == 2)
    }

    @Test func failedCommitLeavesInMemoryStateUntouched() async throws {
        let (seedStore, session) = try await makeSession()
        let initialState = await seedStore.stateSnapshot()
        let store = InMemorySessionStore(initialState: initialState) { _ in
            throw SessionStoreError.invalidRootURL
        }
        await #expect(throws: SessionStoreError.self) {
            try await store.beginTurn(
                sessionID: session.id,
                text: "Must not persist",
                runID: UUID(),
                userMessageID: UUID(),
                at: .now
            )
        }
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(snapshot.messages.isEmpty)
        #expect(snapshot.latestRun == nil)
        #expect(snapshot.activeRun == nil)
    }

    @Test func durableEnumsUseExplicitTaggedCodableShapes() throws {
        let callID = UUID()
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let partData = try encoder.encode(SessionContentPart.toolCall(callID))
        let partObject = try #require(JSONSerialization.jsonObject(with: partData) as? [String: Any])
        #expect(partObject["kind"] as? String == "toolCall")
        #expect(try decoder.decode(SessionContentPart.self, from: partData) == .toolCall(callID))

        let outcomeData = try encoder.encode(SessionRunOutcome.failed(
            SessionFailure(code: "provider_unavailable", message: "Provider unavailable", isRetryable: true)
        ))
        let outcomeObject = try #require(JSONSerialization.jsonObject(with: outcomeData) as? [String: Any])
        #expect(outcomeObject["kind"] as? String == "failed")
        #expect(try decoder.decode(SessionRunOutcome.self, from: outcomeData) == .failed(
            SessionFailure(code: "provider_unavailable", message: "Provider unavailable", isRetryable: true)
        ))
    }

    @Test func permissionDenialIsAtomicAndProducesToolResult() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "write", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let messageID = UUID()
        let callID = UUID()
        let call = SessionToolCall(
            id: callID,
            runID: run.id,
            messageID: messageID,
            ordinal: 0,
            name: "write_file",
            input: ["path": "/tmp/out"]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: messageID,
            content: [.text("Writing"), .toolCall(callID)],
            calls: [call],
            at: .now
        )
        let request = SessionPermissionRequest(
            runID: run.id,
            toolCallID: callID,
            toolName: call.name,
            input: call.input,
            reason: "Write access requires approval"
        )
        try await store.requestPermission(request, at: .now)
        await #expect(throws: SessionStoreError.self) {
            try await store.markToolCallRunning(id: callID, at: .now)
        }
        let resolution = try await store.resolvePermission(
            requestID: request.id,
            decision: .deny(reason: "Not now"),
            deniedResultMessageID: UUID(),
            at: .now
        )
        #expect(resolution.request.status == .denied)
        #expect(resolution.toolCall.status == .denied)
        #expect(resolution.toolResultMessage?.role == .tool)
        #expect(resolution.toolResultMessage?.content == [.toolResult(callID)])
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(snapshot.activeRun?.status == .running)
        #expect(snapshot.pendingPermissionRequests.isEmpty)
    }

    @Test func policyDenialNeedsNoApprovalRequestAndNeverStartsTool() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "write", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let messageID = UUID()
        let callID = UUID()
        let call = SessionToolCall(
            id: callID,
            runID: run.id,
            messageID: messageID,
            ordinal: 0,
            name: "write_file",
            input: ["path": "/workspace/out"]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: messageID,
            content: [.toolCall(callID)],
            calls: [call],
            at: .now
        )
        let (deniedCall, resultMessage) = try await store.denyToolCall(
            id: callID,
            result: .failure("Blocked by policy", kind: .permissionDenied),
            resultMessageID: UUID(),
            at: .now
        )
        #expect(deniedCall.status == .denied)
        #expect(deniedCall.executionDisposition == .notStarted)
        #expect(resultMessage.role == .tool)
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(snapshot.pendingPermissionRequests.isEmpty)
    }

    @Test func allowedToolRunsOnlyAfterApprovalAndPersistsBeforeFollowUp() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "read", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let messageID = UUID()
        let callID = UUID()
        let call = SessionToolCall(
            id: callID,
            runID: run.id,
            messageID: messageID,
            ordinal: 0,
            name: "read_file",
            input: ["path": "/workspace/readme"]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: messageID,
            content: [.toolCall(callID)],
            calls: [call],
            at: .now
        )
        let request = SessionPermissionRequest(
            runID: run.id,
            toolCallID: callID,
            toolName: call.name,
            input: call.input
        )
        try await store.requestPermission(request, at: .now)
        let approved = try await store.resolvePermission(
            requestID: request.id,
            decision: .allow,
            deniedResultMessageID: UUID(),
            at: .now
        )
        #expect(approved.request.status == .allowed)
        let running = try await store.markToolCallRunning(id: callID, at: .now)
        #expect(running.status == .running)
        let (completedCall, toolMessage) = try await store.completeToolCall(
            id: callID,
            result: .success("file contents"),
            resultMessageID: UUID(),
            at: .now
        )
        #expect(completedCall.status == .succeeded)
        #expect(toolMessage.role == .tool)

        let assistant = try await store.startAssistantMessage(
            sessionID: session.id,
            runID: run.id,
            messageID: UUID(),
            initialText: "Here is the file",
            at: .now
        )
        #expect(assistant.sequence > toolMessage.sequence)
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .tool, .assistant])
    }

    @Test func toolResultMessageOrderUsesProviderOrdinalNotCompletionTime() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "two tools", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let messageID = UUID()
        let first = SessionToolCall(
            id: UUID(), runID: run.id, messageID: messageID, ordinal: 0,
            name: "first", input: [:]
        )
        let second = SessionToolCall(
            id: UUID(), runID: run.id, messageID: messageID, ordinal: 1,
            name: "second", input: [:]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: messageID,
            content: [],
            calls: [second, first],
            at: .now
        )
        _ = try await store.markToolCallRunning(id: first.id, at: .now)
        _ = try await store.markToolCallRunning(id: second.id, at: .now)

        _ = try await store.completeToolCall(
            id: second.id, result: .success("second result"), resultMessageID: UUID(), at: .now
        )
        _ = try await store.completeToolCall(
            id: first.id, result: .success("first result"), resultMessageID: UUID(), at: .now
        )
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        let toolMessages = snapshot.messages.filter { $0.role == .tool }
        #expect(toolMessages.count == 2)
        #expect(toolMessages[0].content == [.toolResult(first.id)])
        #expect(toolMessages[1].content == [.toolResult(second.id)])
    }

    @Test func recoveryRetainsCheckpointAndMarksToolOutcomeUncertain() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "do work", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let assistant = try await store.startAssistantMessage(
            sessionID: session.id,
            runID: run.id,
            messageID: UUID(),
            initialText: "Partial",
            at: .now
        )
        // The recovery-specific assertion uses a running call with a durable intent.
        let callMessageID = UUID()
        let callID = UUID()
        let call = SessionToolCall(
            id: callID,
            runID: run.id,
            messageID: callMessageID,
            ordinal: 0,
            name: "write_file",
            input: ["path": "/tmp/out"]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: callMessageID,
            content: [.toolCall(callID)],
            calls: [call],
            at: .now
        )
        _ = try await store.markToolCallRunning(id: callID, at: .now)
        let pendingCallID = UUID()
        let pendingMessageID = UUID()
        let pendingCall = SessionToolCall(
            id: pendingCallID,
            runID: run.id,
            messageID: pendingMessageID,
            ordinal: 1,
            name: "write_file",
            input: ["path": "/tmp/other"]
        )
        _ = try await store.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: pendingMessageID,
            content: [.toolCall(pendingCallID)],
            calls: [pendingCall],
            at: .now
        )
        let request = SessionPermissionRequest(
            runID: run.id,
            toolCallID: pendingCallID,
            toolName: pendingCall.name,
            input: pendingCall.input
        )
        try await store.requestPermission(request, at: .now)
        let recovered = try await store.recoverRun(id: run.id, at: .now)
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(recovered.status == .interrupted)
        #expect(snapshot.activeRun == nil)
        #expect(snapshot.latestRun?.status == .interrupted)
        #expect(snapshot.messages.first(where: { $0.id == assistant.id })?.content == [.text("Partial")])
        #expect(snapshot.messages.first(where: { $0.id == assistant.id })?.status == .interrupted)
        #expect(snapshot.toolCalls.first(where: { $0.id == callID })?.status == .interrupted)
        #expect(snapshot.toolCalls.first(where: { $0.id == callID })?.executionDisposition == .mayHaveExecuted)
        #expect(snapshot.toolCalls.first(where: { $0.id == pendingCallID })?.executionDisposition == .notStarted)
        #expect(snapshot.pendingPermissionRequests.isEmpty)
    }

    @Test func gracefulCancellationFlushesFinalTextWithTerminalState() async throws {
        let (store, session) = try await makeSession()
        let run = try #require(acceptedRun(try await store.beginTurn(
            sessionID: session.id, text: "cancel me", runID: UUID(), userMessageID: UUID(), at: .now
        )))
        let assistant = try await store.startAssistantMessage(
            sessionID: session.id,
            runID: run.id,
            messageID: UUID(),
            initialText: "first",
            at: .now
        )
        let cancelled = try await store.finishRun(
            id: run.id,
            outcome: .cancelled,
            finalAssistantCheckpoints: [
                AssistantTextCheckpoint(
                    messageID: assistant.id,
                    revision: 2,
                    accumulatedText: "first and final delta"
                ),
            ],
            at: .now
        )
        let snapshot = try #require(await store.loadSnapshot(sessionID: session.id))
        #expect(cancelled.status == .cancelled)
        #expect(snapshot.activeRun == nil)
        #expect(snapshot.messages.last?.content == [.text("first and final delta")])
        #expect(snapshot.messages.last?.status == .interrupted)
    }

    @Test func fileBackedStoreReopensInterruptedState() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KernelHarnessKit-SessionStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("store.json")

        let firstStore = try openFileBackedStore(at: file)
        let project = try await firstStore.createProject(Project(name: "Restart"))
        let location = try await firstStore.addLocation(
            projectID: project.id,
            rootURL: URL(fileURLWithPath: "/restart/workspace"),
            name: nil,
            id: UUID(),
            at: .now
        )
        let session = try await firstStore.createSession(
            Session(locationID: location.id, defaultModel: ModelRef(providerID: "mock", modelID: "scripted"))
        )
        let admission = try await firstStore.beginTurn(
            sessionID: session.id,
            text: "persist me",
            runID: UUID(),
            userMessageID: UUID(),
            at: .now
        )
        let run = try #require(acceptedRun(admission))
        let partialMessage = try await firstStore.startAssistantMessage(
            sessionID: session.id,
            runID: run.id,
            messageID: UUID(),
            initialText: "checkpointed partial",
            at: .now
        )
        let toolMessageID = UUID()
        let toolCallID = UUID()
        let toolCall = SessionToolCall(
            id: toolCallID,
            runID: run.id,
            messageID: toolMessageID,
            ordinal: 0,
            name: "write_file",
            input: ["path": "/restart/workspace/out"]
        )
        _ = try await firstStore.persistAssistantToolCalls(
            sessionID: session.id,
            runID: run.id,
            messageID: toolMessageID,
            content: [.toolCall(toolCallID)],
            calls: [toolCall],
            at: .now
        )
        _ = try await firstStore.markToolCallRunning(id: toolCallID, at: .now)

        let reopenedStore = try openFileBackedStore(at: file)
        let recovered = try await reopenedStore.recoverRun(id: run.id, at: .now)
        let snapshot = try #require(await reopenedStore.loadSnapshot(sessionID: session.id))
        #expect(recovered.status == .interrupted)
        #expect(snapshot.messages.map(\.role) == [.user, .assistant, .assistant])
        #expect(snapshot.messages.first?.content == [.text("persist me")])
        #expect(snapshot.messages.first(where: { $0.id == partialMessage.id })?.content == [.text("checkpointed partial")])
        #expect(snapshot.messages.first(where: { $0.id == partialMessage.id })?.status == .interrupted)
        #expect(snapshot.toolCalls.first(where: { $0.id == toolCallID })?.status == .interrupted)
        #expect(snapshot.toolCalls.first(where: { $0.id == toolCallID })?.executionDisposition == .mayHaveExecuted)

        let nextAdmission = try await reopenedStore.beginTurn(
            sessionID: session.id,
            text: "follow up",
            runID: UUID(),
            userMessageID: UUID(),
            at: .now
        )
        let nextRun = try #require(acceptedRun(nextAdmission))
        _ = try await reopenedStore.startAssistantMessage(
            sessionID: session.id,
            runID: nextRun.id,
            messageID: UUID(),
            initialText: "done",
            at: .now
        )
        _ = try await reopenedStore.finishRun(
            id: nextRun.id,
            outcome: .completed,
            finalAssistantCheckpoints: [],
            at: .now
        )

        let finalStore = try openFileBackedStore(at: file)
        let finalSnapshot = try #require(await finalStore.loadSnapshot(sessionID: session.id))
        #expect(finalSnapshot.latestRun?.status == .completed)
        #expect(finalSnapshot.toolCalls.first(where: { $0.id == toolCallID })?.status == .interrupted)
        #expect(finalSnapshot.messages.map(\.sequence) == finalSnapshot.messages.map(\.sequence).sorted())
    }

    private func makeSession() async throws -> (InMemorySessionStore, Session) {
        let store = InMemorySessionStore()
        let project = try await store.createProject(Project(name: "Test"))
        let location = try await store.addLocation(
            projectID: project.id,
            rootURL: URL(fileURLWithPath: "/test/workspace"),
            name: nil,
            id: UUID(),
            at: .now
        )
        let session = try await store.createSession(
            Session(locationID: location.id, defaultModel: ModelRef(providerID: "mock", modelID: "test"))
        )
        return (store, session)
    }

    private func acceptedRun(_ result: TurnAdmissionResult) -> SessionRun? {
        guard case .accepted(let run, _) = result else { return nil }
        return run
    }

    private func openFileBackedStore(at file: URL) throws -> InMemorySessionStore {
        let initial: SessionStoreState
        if FileManager.default.fileExists(atPath: file.path) {
            let data = try Data(contentsOf: file)
            let envelope = try JSONDecoder().decode(FileStoreEnvelope.self, from: data)
            guard envelope.schemaVersion == 1 else {
                throw SessionStoreError.invalidTransition(entity: "file store", id: UUID(), state: "unsupported schema")
            }
            initial = envelope.state
        } else {
            initial = SessionStoreState()
        }
        return InMemorySessionStore(initialState: initial) { state in
            let data = try JSONEncoder().encode(FileStoreEnvelope(schemaVersion: 1, state: state))
            try data.write(to: file, options: .atomic)
        }
    }
}

private struct FileStoreEnvelope: Codable {
    let schemaVersion: Int
    let state: SessionStoreState
}
