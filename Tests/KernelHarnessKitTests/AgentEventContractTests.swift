import Foundation
import Testing
@testable import KernelHarnessKit

@Suite("AgentEvent contract")
struct AgentEventContractTests {
    private func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func json(_ event: AgentEvent) throws -> String {
        let data = try makeEncoder().encode(event)
        return String(decoding: data, as: UTF8.self)
    }

    @Test func exposesStableEventKinds() {
        #expect(AgentEventKind.allCases.map(\.rawValue) == [
            "agent_text_chunk",
            "agent_turn_complete",
            "agent_tool_call_start",
            "agent_tool_call_result",
            "agent_status",
            "agent_error",
            "agent_permission_denied",
            "agent_status_change",
            "agent_todos_updated",
            "agent_sub_agent_start",
            "agent_sub_agent_complete",
            "harness_phase_start",
            "harness_phase_complete",
            "harness_phase_error",
            "harness_complete",
            "harness_batch_start",
            "harness_batch_progress",
            "harness_human_input",
        ])
    }

    @Test func codableRoundTripsRepresentativeEvents() throws {
        let events: [AgentEvent] = [
            .textChunk("hi"),
            .turnComplete(
                ConversationMessage(role: .assistant, text: "done"),
                UsageSnapshot(promptTokens: 2, completionTokens: 3)
            ),
            .toolExecutionStarted(callId: "call_1", name: "read_file", input: ["path": "README.md"]),
            .toolExecutionCompleted(
                callId: "call_1",
                name: "read_file",
                result: .success("ok", metadata: ["bytes": 2])
            ),
            .toolExecutionCompleted(
                callId: "call_2",
                name: "read_file",
                result: .failure("missing", kind: .notFound, details: ["path": "missing.md"])
            ),
            .status("working"),
            .error("failed"),
            .permissionDenied(callId: "call_3", toolName: "write_file", reason: "blocked", input: ["path": "x.md"]),
            .statusChange(.working),
            .todosUpdated([TodoItem(content: "test", status: .inProgress)]),
            .subAgentStarted(id: "a1", description: "research"),
            .subAgentCompleted(id: "a1", summary: "done"),
            .harnessPhaseStart(name: "plan", index: 0, total: 2),
            .harnessPhaseComplete(name: "plan", summary: "ok"),
            .harnessPhaseError(name: "build", error: "boom"),
            .harnessComplete,
            .harnessBatchStart(itemCount: 4),
            .harnessBatchProgress(current: 2, total: 4),
            .harnessHumanInput(question: "Continue?"),
        ]

        let encoder = makeEncoder()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        for event in events {
            let data = try encoder.encode(event)
            let decoded = try decoder.decode(AgentEvent.self, from: data)
            #expect(decoded == event)
        }
    }

    @Test func goldenTraceJSONIsStable() throws {
        let trace: [AgentEvent] = [
            .statusChange(.working),
            .textChunk("Hello"),
            .toolExecutionStarted(callId: "call_abc", name: "read_file", input: ["path": "Package.swift"]),
            .toolExecutionCompleted(callId: "call_abc", name: "read_file", result: .success("// swift-tools-version: 6.0")),
            .turnComplete(ConversationMessage(role: .assistant, text: "Done"), UsageSnapshot(promptTokens: 11, completionTokens: 4)),
        ]

        let data = try makeEncoder().encode(trace)
        let encoded = String(decoding: data, as: UTF8.self)

        #expect(encoded == #"[{"payload":{"status":"working"},"type":"agent_status_change"},{"payload":{"text":"Hello"},"type":"agent_text_chunk"},{"payload":{"id":"call_abc","input":{"path":"Package.swift"},"name":"read_file"},"type":"agent_tool_call_start"},{"payload":{"id":"call_abc","isError":false,"metadata":{},"name":"read_file","output":"// swift-tools-version: 6.0"},"type":"agent_tool_call_result"},{"payload":{"message":{"content":[{"kind":"text","text":"Done"}],"role":"assistant"},"usage":{"completionTokens":4,"promptTokens":11}},"type":"agent_turn_complete"}]"#)
    }

    @Test func convertsToEngineEventEnvelopeWithMetadata() throws {
        let sessionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let eventID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let parentID = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let traceID = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)

        let envelope = AgentEvent.textChunk("hi").engineEnvelope(
            sessionID: sessionID,
            sequence: 42,
            id: eventID,
            protocolVersion: "1.0",
            timestamp: timestamp,
            parentEventID: parentID,
            metadata: AgentEventMetadata(source: "KernelHarnessKit", traceID: traceID, attributes: ["phase": "test"])
        )

        #expect(envelope.id == eventID)
        #expect(envelope.sequence == 42)
        #expect(envelope.sessionID == sessionID)
        #expect(envelope.parentEventID == parentID)
        #expect(envelope.type == "agent_text_chunk")
        #expect(envelope.payload == ["text": "hi"])
        #expect(envelope.metadata.source == "KernelHarnessKit")
        #expect(envelope.metadata.traceID == traceID)
        #expect(envelope.metadata.attributes["phase"] == "test")

        let data = try makeEncoder().encode(envelope)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(EngineEventEnvelope.self, from: data)
        #expect(decoded == envelope)
    }

    @Test func goldenSingleEventJSONIsStable() throws {
        #expect(try json(.harnessPhaseStart(name: "extract", index: 0, total: 3)) == #"{"payload":{"index":0,"name":"extract","total":3},"type":"harness_phase_start"}"#)
    }
}
