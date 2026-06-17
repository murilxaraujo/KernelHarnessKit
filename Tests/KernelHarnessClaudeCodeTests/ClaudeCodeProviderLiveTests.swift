import Foundation
import Logging
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessClaudeCode
@testable import KernelHarnessMCPServer

/// Live tests that drive the real `claude` CLI. They require:
///   * `claude` on PATH and authenticated (`claude auth login` or
///     `ANTHROPIC_API_KEY` with credit)
///   * `KHK_CC_LIVE=1` in the environment
///
/// CI runs without the env var and skips these.
@Suite(
    "ClaudeCodeProvider — live",
    .enabled(if: ProcessInfo.processInfo.environment["KHK_CC_LIVE"] == "1"),
    .serialized
)
struct ClaudeCodeProviderLiveTests {
    @Test("text-only round trip through the real CLI")
    func textOnlyRoundTrip() async throws {
        let provider = ClaudeCodeProvider.local(logger: Logger(label: "live"))

        var deltas: [String] = []
        var finalMessage: ConversationMessage?

        for try await chunk in provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(role: .user, text: "Say only the word READY and nothing else.")],
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        ) {
            switch chunk {
            case .textDelta(let text): deltas.append(text)
            case .messageComplete(let message, _): finalMessage = message
            default: break
            }
        }

        let joined = (finalMessage?.plainText ?? deltas.joined()).uppercased()
        #expect(joined.contains("READY"))
    }

    @Test("tool_use via MCP server round trip")
    func toolUseViaMCP() async throws {
        struct EchoTool: Tool {
            let name = "echo"
            let description = "Echo back the provided message."
            static let inputSchema = JSONSchema.object(
                properties: ["message": .string(description: "Message.")],
                required: ["message"]
            )
            struct Input: Codable, Sendable { let message: String }
            func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
                .success("echoed: \(input.message)")
            }
            func isReadOnly(_ input: Input) -> Bool { true }
        }
        struct AllowAll: PermissionChecker {
            func evaluate(toolName: String, isReadOnly: Bool, filePath: String?, command: String?) -> PermissionDecision { .allow }
        }

        let registry = ToolRegistry()
        registry.register(EchoTool())
        let server = MCPServer(
            toolRegistry: registry,
            contextFactory: {
                ToolExecutionContext(
                    workspace: InMemoryWorkspace(),
                    permissionChecker: AllowAll()
                )
            },
            logger: Logger(label: "live.mcp")
        )
        let handle = try await server.start()

        let provider = ClaudeCodeProvider.local(mcpServer: handle, logger: Logger(label: "live"))

        var finalMessage: ConversationMessage?
        for try await chunk in provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(
                role: .user,
                text: "Call mcp__khk__echo with {\"message\":\"SOTA\"}. Reply with the exact tool output."
            )],
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        ) {
            if case .messageComplete(let message, _) = chunk {
                finalMessage = message
            }
        }

        // CC owns the tool loop when MCP is configured — the final message
        // returned to KHK should be plain text from the model *after* the
        // tool executed, containing the tool's output. No tool_use blocks.
        let text = finalMessage?.plainText ?? ""
        #expect(text.contains("echoed: SOTA"), "final text: \(text)")
        #expect(finalMessage?.toolUses.isEmpty == true, "no tool_use blocks should leak to KHK when CC owns the loop")

        await handle.stop()
    }

    @Test("multi-turn conversation via stream-json stdin preserves history")
    func multiTurnConversation() async throws {
        let provider = ClaudeCodeProvider.local(logger: Logger(label: "live"))

        let messages: [ConversationMessage] = [
            ConversationMessage(role: .user, text: "My favourite number is 42. Say OK."),
            ConversationMessage(role: .assistant, text: "OK."),
            ConversationMessage(role: .user, text: "What number did I just tell you? Reply with only the number."),
        ]

        var finalMessage: ConversationMessage?
        for try await chunk in provider.streamChat(
            model: "haiku",
            messages: messages,
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        ) {
            if case .messageComplete(let message, _) = chunk {
                finalMessage = message
            }
        }

        let text = finalMessage?.plainText ?? ""
        #expect(text.contains("42"), "multi-turn history lost. final text: \(text)")
    }

    @Test("cancellation terminates the underlying claude process")
    func cancellationTerminatesProcess() async throws {
        let provider = ClaudeCodeProvider.local(logger: Logger(label: "live"))

        // Kick off a deliberately slow request, cancel it mid-stream, and
        // verify the stream finishes without leaving the process hanging.
        let stream = provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(
                role: .user,
                text: "Count very slowly to 200, one number per line. Do not stop until you reach 200."
            )],
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        )

        let consumer = Task {
            var chunksSeen = 0
            for try await chunk in stream {
                chunksSeen += 1
                if case .textDelta = chunk, chunksSeen >= 2 {
                    // Got some output — prove the pipeline is live, then
                    // cancel. AsyncStream.onTermination should fire, which
                    // terminates the process.
                    break
                }
            }
        }

        // Give the model ~3s to produce a couple of deltas, then cancel.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        consumer.cancel()
        _ = await consumer.result

        // If the process were leaked, subsequent cleanup would hit a
        // resource wall. Confirm the provider's own preflight still responds
        // (shared actor wasn't corrupted).
        _ = try await provider.preflight.version()
    }

    @Test("workdir is cleaned up after the turn finishes")
    func workdirCleanedUp() async throws {
        let beforeCount = ephemeralWorkdirCount()
        let provider = ClaudeCodeProvider.local(logger: Logger(label: "live"))
        for try await _ in provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(role: .user, text: "Say OK.")],
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        ) {}
        let afterCount = ephemeralWorkdirCount()
        #expect(afterCount <= beforeCount, "ephemeral workdirs leaking in \(NSTemporaryDirectory())")
    }

    private func ephemeralWorkdirCount() -> Int {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        return entries.filter { $0.hasPrefix("khk-cc-") }.count
    }
}
