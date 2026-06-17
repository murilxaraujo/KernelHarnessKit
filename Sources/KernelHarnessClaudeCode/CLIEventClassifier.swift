import Foundation
import KernelHarnessKit

/// Pure parser for the NDJSON events emitted by `claude -p --output-format stream-json`.
///
/// The classifier is deliberately stateless and side-effect free — one line in,
/// one classified event out — so it can be unit-tested against recorded fixture
/// streams. The provider pairs it with a small accumulator to fold text and
/// tool-use deltas into a final `ConversationMessage`.
///
/// ### Event shapes observed on CC 2.1.118
///
/// ```
/// {"type":"system","subtype":"init", ...}              // session metadata
/// {"type":"system","subtype":"status", ...}            // periodic status
/// {"type":"stream_event","event":{...}}                // Anthropic-native events wrapped
/// {"type":"assistant","message":{...}}                 // complete content-block envelope
/// {"type":"user","message":{...}}                      // CC-synthesized tool_result
/// {"type":"rate_limit_event", ...}                     // rate limit snapshot
/// {"type":"result","subtype":"success|error", ...}     // final summary
/// ```
enum ClassifiedEvent: Equatable, Sendable {
    case initMetadata(sessionId: String, apiKeySource: String)
    case messageStart
    case textDelta(String)
    /// A thinking-block delta. KernelHarnessKit has no thinking block type;
    /// the provider discards these unless a caller opts in to surfacing them.
    case thinkingDelta(String)
    case toolUseStart(index: Int, id: String, name: String)
    case toolUseInputDelta(index: Int, partialJSON: String)
    case blockStop(index: Int)
    case messageStop
    /// CC-synthesized user turn carrying a `tool_result` for a `tool_use` that
    /// CC executed internally via MCP. Signals "the previous tool_use block
    /// has been fulfilled; the model will now run another turn."
    case toolResultIngested(toolUseId: String, content: String, isError: Bool)
    case rateLimit(resetsAt: Int64, type: String)
    case turnResult(success: Bool, usage: UsageSnapshot?, errorMessage: String?, errorSubtype: String?)
    case ignored

    static func == (lhs: ClassifiedEvent, rhs: ClassifiedEvent) -> Bool {
        switch (lhs, rhs) {
        case (.initMetadata(let a, let b), .initMetadata(let c, let d)): return a == c && b == d
        case (.messageStart, .messageStart): return true
        case (.textDelta(let a), .textDelta(let b)): return a == b
        case (.thinkingDelta(let a), .thinkingDelta(let b)): return a == b
        case (.toolUseStart(let a, let b, let c), .toolUseStart(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.toolUseInputDelta(let a, let b), .toolUseInputDelta(let c, let d)):
            return a == c && b == d
        case (.blockStop(let a), .blockStop(let b)): return a == b
        case (.messageStop, .messageStop): return true
        case (.toolResultIngested(let a, let b, let c), .toolResultIngested(let d, let e, let f)):
            return a == d && b == e && c == f
        case (.rateLimit(let a, let b), .rateLimit(let c, let d)): return a == c && b == d
        case (.turnResult(let a, let b, let c, let d), .turnResult(let e, let f, let g, let h)):
            return a == e && b == f && c == g && d == h
        case (.ignored, .ignored): return true
        default: return false
        }
    }
}

enum CLIEventClassifier {
    /// Classify a single NDJSON line. `ignored` events are common and
    /// non-fatal — the caller should log them at debug and continue.
    static func classify(line: String) -> ClassifiedEvent {
        guard let data = line.data(using: .utf8),
              let value = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .ignored
        }
        return classify(value: value)
    }

    static func classify(value: JSONValue) -> ClassifiedEvent {
        let type = value["type"]?.stringValue ?? ""
        switch type {
        case "system":
            if value["subtype"]?.stringValue == "init" {
                let sid = value["session_id"]?.stringValue ?? ""
                let key = value["apiKeySource"]?.stringValue ?? ""
                return .initMetadata(sessionId: sid, apiKeySource: key)
            }
            return .ignored

        case "stream_event":
            return classifyStreamEvent(value["event"] ?? .null)

        case "assistant":
            // The assistant summary envelope duplicates what stream_event
            // deltas already provided — we rely on stream_event for deltas
            // and ignore the summary.
            return .ignored

        case "user":
            // CC-synthesized tool_result from internally-executed MCP tools.
            // Extract so the provider can surface it via logger/telemetry.
            if let content = value["message"]?["content"]?.arrayValue {
                for entry in content {
                    if entry["type"]?.stringValue == "tool_result",
                       let id = entry["tool_use_id"]?.stringValue {
                        let isError = entry["is_error"]?.boolValue ?? false
                        let text = (entry["content"]?.arrayValue?
                            .compactMap { $0["text"]?.stringValue }
                            .joined(separator: "\n")) ?? ""
                        return .toolResultIngested(toolUseId: id, content: text, isError: isError)
                    }
                }
            }
            return .ignored

        case "rate_limit_event":
            if let info = value["rate_limit_info"] {
                let resets = info["resetsAt"]?.intValue ?? 0
                let type = info["rateLimitType"]?.stringValue ?? ""
                return .rateLimit(resetsAt: resets, type: type)
            }
            return .ignored

        case "result":
            let subtype = value["subtype"]?.stringValue ?? ""
            let isError = value["is_error"]?.boolValue ?? subtype.hasPrefix("error")
            let usage = parseUsage(value["usage"])
            if isError {
                let fallback = "claude cli failed (subtype: \(subtype))"
                let explicitMessage = value["result"]?.stringValue
                let errorsArray = value["errors"]?.arrayValue?.compactMap { $0.stringValue }.joined(separator: "; ")
                let apiStatus = value["api_error_status"]?.stringValue
                let parts = [explicitMessage, errorsArray, apiStatus.map { "api_error_status: \($0)" }]
                    .compactMap { $0 }
                    .filter { !$0.isEmpty }
                let message = parts.isEmpty ? fallback : parts.joined(separator: " | ")
                return .turnResult(success: false, usage: usage, errorMessage: message, errorSubtype: subtype)
            } else {
                return .turnResult(success: true, usage: usage, errorMessage: nil, errorSubtype: nil)
            }

        default:
            return .ignored
        }
    }

    private static func classifyStreamEvent(_ event: JSONValue) -> ClassifiedEvent {
        let type = event["type"]?.stringValue ?? ""
        switch type {
        case "message_start":
            return .messageStart

        case "content_block_start":
            let index = Int(event["index"]?.intValue ?? 0)
            let block = event["content_block"]
            let blockType = block?["type"]?.stringValue ?? ""
            if blockType == "tool_use",
               let id = block?["id"]?.stringValue,
               let name = block?["name"]?.stringValue {
                return .toolUseStart(index: index, id: id, name: name)
            }
            return .ignored

        case "content_block_delta":
            let index = Int(event["index"]?.intValue ?? 0)
            let delta = event["delta"]
            let dtype = delta?["type"]?.stringValue ?? ""
            switch dtype {
            case "text_delta":
                return .textDelta(delta?["text"]?.stringValue ?? "")
            case "thinking_delta":
                return .thinkingDelta(delta?["thinking"]?.stringValue ?? "")
            case "signature_delta":
                // Thinking block signature — drop. We don't replay thinking.
                return .ignored
            case "input_json_delta":
                return .toolUseInputDelta(
                    index: index,
                    partialJSON: delta?["partial_json"]?.stringValue ?? ""
                )
            default:
                return .ignored
            }

        case "content_block_stop":
            let index = Int(event["index"]?.intValue ?? 0)
            return .blockStop(index: index)

        case "message_delta":
            return .ignored

        case "message_stop":
            return .messageStop

        default:
            return .ignored
        }
    }

    private static func parseUsage(_ value: JSONValue?) -> UsageSnapshot? {
        guard let value else { return nil }
        let prompt = Int(value["input_tokens"]?.intValue ?? 0)
        let completion = Int(value["output_tokens"]?.intValue ?? 0)
        return UsageSnapshot(promptTokens: prompt, completionTokens: completion)
    }
}
