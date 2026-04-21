import Foundation

/// Encodes ``AgentEvent`` values as Server-Sent Events lines.
///
/// ``AgentEvent`` is consumer-agnostic — the engine emits it, the consumer
/// decides the transport. ``SSEEncoder`` is the standard serialization used by
/// consumers who speak SSE (most commonly a Vapor or Hummingbird HTTP app
/// serving a `text/event-stream` response).
///
/// Output shape:
///
/// ```text
/// event: agent_text_chunk
/// data: {"text":"hello"}
///
/// ```
///
/// Each encoded event is terminated with a blank line as required by the
/// SSE spec. Consumers concatenate the strings and send them as UTF-8.
public struct SSEEncoder: Sendable {
    private let encoder: JSONEncoder

    public init(encoder: JSONEncoder = .init()) {
        let e = encoder
        e.outputFormatting = [.sortedKeys]
        self.encoder = e
    }

    /// Encode a single event.
    public func encode(_ event: AgentEvent) -> String {
        let type = event.eventType
        let data = (try? encoder.encode(event.jsonPayload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "event: \(type)\ndata: \(data)\n\n"
    }
}

// MARK: - Event type + payload projection

extension AgentEvent {
    /// SSE `event:` tag.
    public var eventType: String {
        switch self {
        case .textChunk:              return "agent_text_chunk"
        case .turnComplete:           return "agent_turn_complete"
        case .toolExecutionStarted:   return "agent_tool_call_start"
        case .toolExecutionCompleted: return "agent_tool_call_result"
        case .status:                 return "agent_status"
        case .error:                  return "agent_error"
        case .statusChange:           return "agent_status_change"
        case .todosUpdated:           return "agent_todos_updated"
        case .subAgentStarted:        return "agent_sub_agent_start"
        case .subAgentCompleted:      return "agent_sub_agent_complete"
        case .harnessPhaseStart:      return "harness_phase_start"
        case .harnessPhaseComplete:   return "harness_phase_complete"
        case .harnessPhaseError:      return "harness_phase_error"
        case .harnessComplete:        return "harness_complete"
        case .harnessBatchStart:      return "harness_batch_start"
        case .harnessBatchProgress:   return "harness_batch_progress"
        case .harnessHumanInput:      return "harness_human_input"
        }
    }

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
}
