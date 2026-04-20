import Foundation

/// A minimal Server-Sent Events parser.
///
/// Accumulates incoming UTF-8 bytes, splits them into events at blank lines,
/// and emits decoded ``SSEEvent`` values. The parser is permissive — it
/// ignores comment lines (`:` prefix) and handles both LF and CRLF line
/// endings.
struct SSEParser {
    /// A parsed Server-Sent Event.
    struct SSEEvent: Sendable, Hashable {
        /// The event name (`event:` field). Defaults to `"message"`.
        var name: String = "message"
        /// The accumulated data lines joined by `\n`.
        var data: String = ""
        /// Optional event id.
        var id: String?
    }

    /// Parse a complete SSE byte stream into events.
    static func parse(_ data: Data) -> [SSEEvent] {
        var events: [SSEEvent] = []
        let lines = String(decoding: data, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        var current = SSEEvent()
        for line in lines {
            if line.isEmpty {
                if !current.data.isEmpty {
                    events.append(current)
                }
                current = SSEEvent()
                continue
            }
            if line.hasPrefix(":") { continue }

            if let colon = line.firstIndex(of: ":") {
                let field = String(line[..<colon])
                var value = String(line[line.index(after: colon)...])
                if value.hasPrefix(" ") { value.removeFirst() }
                apply(field: field, value: value, to: &current)
            } else {
                apply(field: line, value: "", to: &current)
            }
        }
        if !current.data.isEmpty {
            events.append(current)
        }
        return events
    }

    /// Parse from an async byte stream, yielding events as they complete.
    static func stream<S: AsyncSequence>(from bytes: S) -> AsyncThrowingStream<SSEEvent, Error>
    where S.Element == UInt8, S: Sendable
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var buffer = [UInt8]()
                    var current = SSEEvent()
                    for try await byte in bytes {
                        buffer.append(byte)
                        // Flush completed lines on LF.
                        if byte == 0x0A {
                            var lineBytes = buffer.dropLast()  // drop LF
                            if lineBytes.last == 0x0D {        // strip trailing CR
                                lineBytes = lineBytes.dropLast()
                            }
                            let line = String(decoding: Array(lineBytes), as: UTF8.self)
                            buffer.removeAll(keepingCapacity: true)

                            if line.isEmpty {
                                if !current.data.isEmpty {
                                    continuation.yield(current)
                                }
                                current = SSEEvent()
                                continue
                            }
                            if line.hasPrefix(":") { continue }
                            if let colon = line.firstIndex(of: ":") {
                                let field = String(line[..<colon])
                                var value = String(line[line.index(after: colon)...])
                                if value.hasPrefix(" ") { value.removeFirst() }
                                apply(field: field, value: value, to: &current)
                            } else {
                                apply(field: line, value: "", to: &current)
                            }
                        }
                    }
                    if !current.data.isEmpty {
                        continuation.yield(current)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func apply(field: String, value: String, to event: inout SSEEvent) {
        switch field {
        case "event":
            event.name = value
        case "data":
            if event.data.isEmpty {
                event.data = value
            } else {
                event.data.append("\n")
                event.data.append(value)
            }
        case "id":
            event.id = value
        default:
            break
        }
    }
}
