import Foundation
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessClaudeCode

@Suite("ConversationSerialization")
struct ConversationSerializationTests {
    @Test("user text message becomes {type:user, content:[{type:text,text}]}")
    func userTextMessage() throws {
        let message = ConversationMessage(role: .user, text: "hi there")
        let line = try ConversationSerialization.streamJSONLine(for: message)!
        let decoded = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(decoded["type"] as? String == "user")
        let inner = decoded["message"] as! [String: Any]
        #expect(inner["role"] as? String == "user")
        let content = inner["content"] as! [[String: Any]]
        #expect(content.first?["type"] as? String == "text")
        #expect(content.first?["text"] as? String == "hi there")
    }

    @Test("assistant with tool_use encodes input as JSON object")
    func assistantToolUse() throws {
        let message = ConversationMessage(
            role: .assistant,
            content: [
                .text("Let me check."),
                .toolUse(id: "toolu_1", name: "echo", input: ["message": .string("hello")]),
            ]
        )
        let line = try ConversationSerialization.streamJSONLine(for: message)!
        let decoded = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(decoded["type"] as? String == "assistant")
        let content = (decoded["message"] as! [String: Any])["content"] as! [[String: Any]]
        #expect(content.count == 2)
        #expect(content[0]["type"] as? String == "text")
        #expect(content[1]["type"] as? String == "tool_use")
        #expect(content[1]["id"] as? String == "toolu_1")
        #expect(content[1]["name"] as? String == "echo")
        let input = content[1]["input"] as! [String: Any]
        #expect(input["message"] as? String == "hello")
    }

    @Test("tool role with toolResult encodes as user tool_result")
    func toolResult() throws {
        let message = ConversationMessage(
            role: .tool,
            content: [.toolResult(toolUseId: "toolu_1", content: "echoed: hello", isError: false)]
        )
        let line = try ConversationSerialization.streamJSONLine(for: message)!
        let decoded = try JSONSerialization.jsonObject(with: line) as! [String: Any]
        #expect(decoded["type"] as? String == "user")
        let content = (decoded["message"] as! [String: Any])["content"] as! [[String: Any]]
        #expect(content[0]["type"] as? String == "tool_result")
        #expect(content[0]["tool_use_id"] as? String == "toolu_1")
    }

    @Test("system messages produce no line (passed via --system-prompt)")
    func systemMessageSkipped() throws {
        let message = ConversationMessage(role: .system, text: "you are friendly")
        let line = try ConversationSerialization.streamJSONLine(for: message)
        #expect(line == nil)
    }

    @Test("combinedSystemPrompt merges explicit + role:.system content")
    func combinedSystemPrompt() {
        let messages = [
            ConversationMessage(role: .system, text: "Extra: be concise."),
            ConversationMessage(role: .user, text: "hi"),
        ]
        let combined = ConversationSerialization.combinedSystemPrompt(messages: messages, explicit: "You are helpful.")
        #expect(combined == "You are helpful.\n\nExtra: be concise.")
    }

    @Test("streamJSONLines preserves order across multiple messages")
    func streamJSONLinesOrder() throws {
        let messages = [
            ConversationMessage(role: .system, text: "ignored"),
            ConversationMessage(role: .user, text: "first"),
            ConversationMessage(role: .assistant, text: "reply"),
            ConversationMessage(role: .user, text: "second"),
        ]
        let lines = try ConversationSerialization.streamJSONLines(for: messages)
        #expect(lines.count == 3)
    }
}
