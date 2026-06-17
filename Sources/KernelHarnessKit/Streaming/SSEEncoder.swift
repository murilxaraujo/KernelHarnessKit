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
