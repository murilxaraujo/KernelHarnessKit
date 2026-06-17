import Foundation
import KernelHarnessKit

/// Builds `--input-format stream-json` NDJSON lines from KernelHarnessKit's
/// `ConversationMessage` history.
///
/// Claude Code's stream-json stdin is an interactive REPL: each
/// `{"type":"user","message":{...}}` line triggers a fresh assistant turn in
/// the session. To pre-seed a multi-turn conversation we issue the history as
/// a sequence of user / assistant lines — CC accepts any interleaving the
/// Anthropic API would accept.
enum ConversationSerialization {
    /// Render the full conversation as ordered NDJSON lines. The caller writes
    /// these to the CC process's stdin in order.
    ///
    /// Only the turns that model expects to see are emitted — system prompts
    /// are passed via `--system-prompt`, not as inline messages.
    static func streamJSONLines(for messages: [ConversationMessage]) throws -> [Data] {
        var lines: [Data] = []
        for message in messages {
            guard let line = try streamJSONLine(for: message) else { continue }
            lines.append(line)
        }
        return lines
    }

    /// Render a single conversation message as one NDJSON line, or `nil` if
    /// it has no representation in the CC stream (e.g. system messages).
    static func streamJSONLine(for message: ConversationMessage) throws -> Data? {
        switch message.role {
        case .system:
            return nil
        case .user, .tool:
            let envelope = try userEnvelope(message)
            return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        case .assistant:
            let envelope = try assistantEnvelope(message)
            return try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        }
    }

    private static func userEnvelope(_ message: ConversationMessage) throws -> [String: Any] {
        var blocks: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let text):
                blocks.append(["type": "text", "text": text])
            case .image:
                // Images in user messages are expressible via content blocks
                // but CC's stream-json accepts them only when encoded as base64
                // data-URL under the `source.data` key per Anthropic's schema.
                // Skipped for v1 — most KHK tool calls don't produce images.
                continue
            case .toolResult(let toolUseId, let content, let isError):
                var entry: [String: Any] = [
                    "type": "tool_result",
                    "tool_use_id": toolUseId,
                    "content": [["type": "text", "text": content]],
                ]
                if isError { entry["is_error"] = true }
                blocks.append(entry)
            case .toolUse:
                // Tool uses never originate from the user role.
                continue
            }
        }
        let content: Any = blocks.isEmpty ? "" : blocks
        return [
            "type": "user",
            "message": [
                "role": "user",
                "content": content,
            ],
        ]
    }

    private static func assistantEnvelope(_ message: ConversationMessage) throws -> [String: Any] {
        var blocks: [[String: Any]] = []
        for block in message.content {
            switch block {
            case .text(let text):
                blocks.append(["type": "text", "text": text])
            case .toolUse(let id, let name, let input):
                let inputValue: [String: Any]
                do {
                    let data = try JSONEncoder().encode(input)
                    inputValue = try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                } catch {
                    inputValue = [:]
                }
                blocks.append([
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": inputValue,
                ])
            case .image, .toolResult:
                continue
            }
        }
        return [
            "type": "assistant",
            "message": [
                "role": "assistant",
                "content": blocks,
            ],
        ]
    }

    /// Find the system-prompt text composed of any `.system` messages plus the
    /// caller-supplied `systemPrompt`. Passed via `--system-prompt`.
    static func combinedSystemPrompt(messages: [ConversationMessage], explicit: String?) -> String? {
        var parts: [String] = []
        if let explicit, !explicit.isEmpty {
            parts.append(explicit)
        }
        for message in messages where message.role == .system {
            let text = message.plainText
            if !text.isEmpty { parts.append(text) }
        }
        let combined = parts.joined(separator: "\n\n")
        return combined.isEmpty ? nil : combined
    }
}
