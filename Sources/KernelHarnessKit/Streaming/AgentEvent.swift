import Foundation

/// Stable event names emitted by KernelHarnessKit.
///
/// These raw values are part of the public event contract. Transports may map
/// them to their own framing names, but should not invent different semantic
/// event identifiers.
public enum AgentEventKind: String, Codable, Sendable, Hashable, CaseIterable {
    case textChunk = "agent_text_chunk"
    case turnComplete = "agent_turn_complete"
    case toolExecutionStarted = "agent_tool_call_start"
    case toolExecutionCompleted = "agent_tool_call_result"
    case status = "agent_status"
    case error = "agent_error"
    case statusChange = "agent_status_change"
    case todosUpdated = "agent_todos_updated"
    case subAgentStarted = "agent_sub_agent_start"
    case subAgentCompleted = "agent_sub_agent_complete"
    case harnessPhaseStart = "harness_phase_start"
    case harnessPhaseComplete = "harness_phase_complete"
    case harnessPhaseError = "harness_phase_error"
    case harnessComplete = "harness_complete"
    case harnessBatchStart = "harness_batch_start"
    case harnessBatchProgress = "harness_batch_progress"
    case harnessHumanInput = "harness_human_input"
}

/// Optional metadata that can be attached when adapting a harness event to an
/// engine-level stream.
public struct AgentEventMetadata: Codable, Sendable, Hashable {
    public var source: String?
    public var traceID: UUID?
    public var attributes: [String: JSONValue]

    public init(
        source: String? = nil,
        traceID: UUID? = nil,
        attributes: [String: JSONValue] = [:]
    ) {
        self.source = source
        self.traceID = traceID
        self.attributes = attributes
    }
}

/// A transport-neutral engine event envelope built from an ``AgentEvent``.
///
/// KernelEngine may persist this shape directly or project it into its own
/// schema. The important contract is stable: event identity, ordering,
/// timestamps, session correlation, parent correlation, event type, structured
/// payload, and metadata.
public struct EngineEventEnvelope: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var sequence: Int64
    public var protocolVersion: String
    public var timestamp: Date
    public var sessionID: UUID
    public var parentEventID: UUID?
    public var type: String
    public var payload: JSONValue
    public var metadata: AgentEventMetadata

    public init(
        id: UUID = UUID(),
        sequence: Int64,
        protocolVersion: String = "1.0",
        timestamp: Date = Date(),
        sessionID: UUID,
        parentEventID: UUID? = nil,
        type: String,
        payload: JSONValue,
        metadata: AgentEventMetadata = .init()
    ) {
        self.id = id
        self.sequence = sequence
        self.protocolVersion = protocolVersion
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.parentEventID = parentEventID
        self.type = type
        self.payload = payload
        self.metadata = metadata
    }
}

/// Every event the engine or harness can emit.
///
/// Events are produced by the agent loop, the harness engine, and the
/// built-in tools. Consumers subscribe via the `AsyncThrowingStream` returned
/// from ``runAgent(context:initialMessages:)`` or ``HarnessEngine/run()`` and
/// encode them into their transport of choice (SSE, XPC callbacks, WebSocket,
/// JSON log line).
public enum AgentEvent: Codable, Sendable, Hashable {
    // MARK: Engine events
    /// A text delta from the model (streamed word-by-word).
    case textChunk(String)
    /// A full turn is complete: the assistant message and its usage.
    case turnComplete(ConversationMessage, UsageSnapshot?)
    /// A tool call has started. `input` is the validated arguments.
    ///
    /// `callId` is the stable tool-use identifier assigned by the model
    /// (e.g. `call_abc123` from OpenAI, or `toolu_xxx` from Anthropic). It
    /// matches the `id` field on the corresponding ``ContentBlock/toolUse(id:name:input:)``
    /// and lets transport-layer consumers correlate started/completed pairs
    /// even when multiple invocations of the same tool run in parallel.
    case toolExecutionStarted(callId: String, name: String, input: [String: JSONValue])
    /// A tool call has finished. `callId` matches the started event.
    case toolExecutionCompleted(callId: String, name: String, result: ToolResult)
    /// A generic status message (e.g., "Retrying in 2s: rate limited").
    case status(String)
    /// An error occurred.
    case error(String)

    // MARK: Coordination events
    /// The agent's state machine changed.
    case statusChange(AgentStatus)
    /// The todo list was replaced.
    case todosUpdated([TodoItem])
    /// A sub-agent started.
    case subAgentStarted(id: String, description: String)
    /// A sub-agent completed with a short summary.
    case subAgentCompleted(id: String, summary: String)

    // MARK: Harness events
    /// A phase started.
    case harnessPhaseStart(name: String, index: Int, total: Int)
    /// A phase completed.
    case harnessPhaseComplete(name: String, summary: String)
    /// A phase errored.
    case harnessPhaseError(name: String, error: String)
    /// The harness completed.
    case harnessComplete
    /// A batch phase began — there are `itemCount` items to process.
    case harnessBatchStart(itemCount: Int)
    /// Progress update inside a batch phase.
    case harnessBatchProgress(current: Int, total: Int)
    /// Human input required — the engine is waiting for the user to respond.
    case harnessHumanInput(question: String)
}

// MARK: - Event type + payload projection

extension AgentEvent {
    /// Stable event kind.
    public var kind: AgentEventKind {
        switch self {
        case .textChunk:              return .textChunk
        case .turnComplete:           return .turnComplete
        case .toolExecutionStarted:   return .toolExecutionStarted
        case .toolExecutionCompleted: return .toolExecutionCompleted
        case .status:                 return .status
        case .error:                  return .error
        case .statusChange:           return .statusChange
        case .todosUpdated:           return .todosUpdated
        case .subAgentStarted:        return .subAgentStarted
        case .subAgentCompleted:      return .subAgentCompleted
        case .harnessPhaseStart:      return .harnessPhaseStart
        case .harnessPhaseComplete:   return .harnessPhaseComplete
        case .harnessPhaseError:      return .harnessPhaseError
        case .harnessComplete:        return .harnessComplete
        case .harnessBatchStart:      return .harnessBatchStart
        case .harnessBatchProgress:   return .harnessBatchProgress
        case .harnessHumanInput:      return .harnessHumanInput
        }
    }

    /// Transport-friendly event type string.
    public var eventType: String { kind.rawValue }

    /// Flat, JSON-encodable payload projection of the event's associated
    /// values. Stable across releases — consumers may parse these on the
    /// client side.
    public var jsonPayload: JSONValue {
        switch self {
        case .textChunk(let text):
            return ["text": .string(text)]
        case .turnComplete(let message, let usage):
            return [
                "message": (try? JSONValue(encoding: message)) ?? .null,
                "usage": usage.flatMap { try? JSONValue(encoding: $0) } ?? .null,
            ]
        case .toolExecutionStarted(let callId, let name, let input):
            return [
                "id": .string(callId),
                "name": .string(name),
                "input": .object(input),
            ]
        case .toolExecutionCompleted(let callId, let name, let result):
            return [
                "id": .string(callId),
                "name": .string(name),
                "output": .string(result.output),
                "isError": .bool(result.isError),
                "metadata": .object(result.metadata),
            ]
        case .status(let text):
            return ["message": .string(text)]
        case .error(let message):
            return ["message": .string(message)]
        case .statusChange(let status):
            return ["status": .string(status.rawValue)]
        case .todosUpdated(let items):
            return ["todos": (try? JSONValue(encoding: items)) ?? .array([])]
        case .subAgentStarted(let id, let description):
            return ["id": .string(id), "description": .string(description)]
        case .subAgentCompleted(let id, let summary):
            return ["id": .string(id), "summary": .string(summary)]
        case .harnessPhaseStart(let name, let index, let total):
            return [
                "name": .string(name),
                "index": .integer(Int64(index)),
                "total": .integer(Int64(total)),
            ]
        case .harnessPhaseComplete(let name, let summary):
            return ["name": .string(name), "summary": .string(summary)]
        case .harnessPhaseError(let name, let error):
            return ["name": .string(name), "error": .string(error)]
        case .harnessComplete:
            return .object([:])
        case .harnessBatchStart(let count):
            return ["itemCount": .integer(Int64(count))]
        case .harnessBatchProgress(let current, let total):
            return [
                "current": .integer(Int64(current)),
                "total": .integer(Int64(total)),
            ]
        case .harnessHumanInput(let question):
            return ["question": .string(question)]
        }
    }

    /// Convert this harness event into an engine event envelope ready for
    /// persistence, replay, or transport delivery.
    public func engineEnvelope(
        sessionID: UUID,
        sequence: Int64,
        id: UUID = UUID(),
        protocolVersion: String = "1.0",
        timestamp: Date = Date(),
        parentEventID: UUID? = nil,
        metadata: AgentEventMetadata = .init()
    ) -> EngineEventEnvelope {
        EngineEventEnvelope(
            id: id,
            sequence: sequence,
            protocolVersion: protocolVersion,
            timestamp: timestamp,
            sessionID: sessionID,
            parentEventID: parentEventID,
            type: eventType,
            payload: jsonPayload,
            metadata: metadata
        )
    }
}

// MARK: - Codable

extension AgentEvent {
    private enum CodingKeys: String, CodingKey {
        case type
        case payload
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(AgentEventKind.self, forKey: .type)
        let payload = try c.decode(JSONValue.self, forKey: .payload)
        guard case .object(let object) = payload else {
            throw DecodingError.dataCorruptedError(
                forKey: .payload,
                in: c,
                debugDescription: "AgentEvent payload must be a JSON object"
            )
        }

        func required(_ key: String) throws -> JSONValue {
            guard let value = object[key] else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload,
                    in: c,
                    debugDescription: "Missing AgentEvent payload key: \(key)"
                )
            }
            return value
        }

        func string(_ key: String) throws -> String {
            guard let value = try required(key).stringValue else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload,
                    in: c,
                    debugDescription: "AgentEvent payload key \(key) must be a string"
                )
            }
            return value
        }

        func int(_ key: String) throws -> Int {
            guard let value = try required(key).intValue else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload,
                    in: c,
                    debugDescription: "AgentEvent payload key \(key) must be an integer"
                )
            }
            return Int(value)
        }

        switch kind {
        case .textChunk:
            self = .textChunk(try string("text"))
        case .turnComplete:
            let message = try required("message").decode(as: ConversationMessage.self)
            let usageValue = object["usage"] ?? .null
            let usage = usageValue.isNull ? nil : try usageValue.decode(as: UsageSnapshot.self)
            self = .turnComplete(message, usage)
        case .toolExecutionStarted:
            let input = object["input"]?.objectValue ?? [:]
            self = .toolExecutionStarted(callId: try string("id"), name: try string("name"), input: input)
        case .toolExecutionCompleted:
            let metadata = object["metadata"]?.objectValue ?? [:]
            let isError = (object["isError"]?.boolValue) ?? false
            let result = ToolResult(output: try string("output"), isError: isError, metadata: metadata)
            self = .toolExecutionCompleted(callId: try string("id"), name: try string("name"), result: result)
        case .status:
            self = .status(try string("message"))
        case .error:
            self = .error(try string("message"))
        case .statusChange:
            guard let status = AgentStatus(rawValue: try string("status")) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .payload,
                    in: c,
                    debugDescription: "Unknown AgentStatus"
                )
            }
            self = .statusChange(status)
        case .todosUpdated:
            self = .todosUpdated(try required("todos").decode(as: [TodoItem].self))
        case .subAgentStarted:
            self = .subAgentStarted(id: try string("id"), description: try string("description"))
        case .subAgentCompleted:
            self = .subAgentCompleted(id: try string("id"), summary: try string("summary"))
        case .harnessPhaseStart:
            self = .harnessPhaseStart(name: try string("name"), index: try int("index"), total: try int("total"))
        case .harnessPhaseComplete:
            self = .harnessPhaseComplete(name: try string("name"), summary: try string("summary"))
        case .harnessPhaseError:
            self = .harnessPhaseError(name: try string("name"), error: try string("error"))
        case .harnessComplete:
            self = .harnessComplete
        case .harnessBatchStart:
            self = .harnessBatchStart(itemCount: try int("itemCount"))
        case .harnessBatchProgress:
            self = .harnessBatchProgress(current: try int("current"), total: try int("total"))
        case .harnessHumanInput:
            self = .harnessHumanInput(question: try string("question"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .type)
        try c.encode(jsonPayload, forKey: .payload)
    }
}
