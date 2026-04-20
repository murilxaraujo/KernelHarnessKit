import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("ConversationMessage")
struct ConversationMessageTests {
    @Test func textMessageConvenience() {
        let msg = ConversationMessage(role: .user, text: "hello")
        #expect(msg.plainText == "hello")
        #expect(msg.toolUses.isEmpty)
    }

    @Test func extractsToolUses() {
        let msg = ConversationMessage(role: .assistant, content: [
            .text("let me check"),
            .toolUse(id: "t1", name: "read_file", input: ["path": "/x"]),
            .toolUse(id: "t2", name: "write_file", input: ["path": "/y", "content": "hi"]),
        ])
        let calls = msg.toolUses
        #expect(calls.count == 2)
        #expect(calls[0].name == "read_file")
        #expect(calls[0].input["path"]?.stringValue == "/x")
        #expect(calls[1].id == "t2")
    }

    @Test func codableRoundTrip() throws {
        let original = ConversationMessage(role: .assistant, content: [
            .text("thinking"),
            .toolUse(id: "u-1", name: "search", input: ["query": "swift"]),
            .toolResult(toolUseId: "u-0", content: "ok", isError: false),
        ])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationMessage.self, from: data)
        #expect(decoded == original)
    }
}
