import Foundation
import Logging
import Testing
@testable import KernelHarnessKit
@testable import KernelHarnessClaudeCode

/// End-to-end provider tests that replace the `claude` binary with a shell
/// shim emitting canned `stream-json` output. Exercises the subprocess, stdin
/// piping, stdout parsing, and `StreamChunk` yield path — without requiring
/// the real CLI (or its authentication) on the host machine.
@Suite("ClaudeCodeProvider — shim")
struct ClaudeCodeProviderShimTests {
    @Test("end-to-end streams text and completes with assistant message")
    func streamsTextAndCompletes() async throws {
        let shim = try Shim(ndjson: textOnlyFixture)
        defer { shim.cleanup() }

        let provider = ClaudeCodeProvider(
            executablePath: shim.path,
            logger: Logger(label: "test"),
        )

        var deltas: [String] = []
        var finalMessage: ConversationMessage?

        let stream = provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(role: .user, text: "say hi")],
            systemPrompt: nil,
            tools: nil,
            responseFormat: nil,
            temperature: nil,
            maxTokens: nil
        )

        for try await chunk in stream {
            switch chunk {
            case .textDelta(let text):
                deltas.append(text)
            case .messageComplete(let message, _):
                finalMessage = message
            default:
                break
            }
        }

        #expect(deltas.joined() == "Hello world")
        #expect(finalMessage?.plainText == "Hello world")
    }

    @Test("end-to-end captures tool_use blocks in final message")
    func capturesToolUse() async throws {
        let shim = try Shim(ndjson: toolUseFixture)
        defer { shim.cleanup() }

        let provider = ClaudeCodeProvider(
            executablePath: shim.path,
            logger: Logger(label: "test"),
        )

        var finalMessage: ConversationMessage?

        for try await chunk in provider.streamChat(
            model: "haiku",
            messages: [ConversationMessage(role: .user, text: "use a tool")],
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

        let toolUses = finalMessage?.toolUses ?? []
        #expect(toolUses.count == 1)
        #expect(toolUses.first?.name == "echo")
        #expect(toolUses.first?.id == "toolu_abc")
        #expect(toolUses.first?.input["message"] == .string("hi"))
    }

    @Test("cli error result is surfaced as ClaudeCodeProviderError.cliError")
    func cliErrorSurfaces() async throws {
        let shim = try Shim(ndjson: errorFixture)
        defer { shim.cleanup() }

        let provider = ClaudeCodeProvider(
            executablePath: shim.path,
            logger: Logger(label: "test"),
        )

        var thrown: Error?
        do {
            for try await _ in provider.streamChat(
                model: "haiku",
                messages: [ConversationMessage(role: .user, text: "go")],
                systemPrompt: nil,
                tools: nil,
                responseFormat: nil,
                temperature: nil,
                maxTokens: nil
            ) {}
        } catch {
            thrown = error
        }

        guard case ClaudeCodeProviderError.cliError(let msg) = (thrown as? ClaudeCodeProviderError) ?? .cancelled else {
            Issue.record("expected cliError, got \(String(describing: thrown))")
            return
        }
        #expect(msg.contains("rate limit"))
    }

    // MARK: - Fixtures

    private let textOnlyFixture: String = """
    {"type":"system","subtype":"init","session_id":"s1","apiKeySource":"none"}
    {"type":"stream_event","event":{"type":"message_start","message":{"id":"m1"}}}
    {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello "}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"world"}}}
    {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"Hello world","usage":{"input_tokens":5,"output_tokens":3}}
    """

    private let toolUseFixture: String = """
    {"type":"system","subtype":"init","session_id":"s2","apiKeySource":"none"}
    {"type":"stream_event","event":{"type":"message_start","message":{"id":"m2"}}}
    {"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_abc","name":"echo","input":{}}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"mess"}}}
    {"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"age\\":\\"hi\\"}"}}}
    {"type":"stream_event","event":{"type":"content_block_stop","index":0}}
    {"type":"stream_event","event":{"type":"message_stop"}}
    {"type":"result","subtype":"success","is_error":false,"result":"","usage":{"input_tokens":5,"output_tokens":3}}
    """

    private let errorFixture: String = """
    {"type":"system","subtype":"init","session_id":"s3","apiKeySource":"none"}
    {"type":"result","subtype":"error","is_error":true,"result":"rate limit exceeded"}
    """
}

/// A self-cleaning shell script pretending to be `claude` for test purposes.
/// The script ignores its flags and stdin and cats a fixed NDJSON blob to
/// stdout.
private struct Shim {
    let path: String
    private let directory: URL

    init(ndjson: String) throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("khk-cc-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let fixture = dir.appendingPathComponent("stream.ndjson")
        try ndjson.write(to: fixture, atomically: true, encoding: .utf8)

        let versionScript = dir.appendingPathComponent("claude")
        let script = """
        #!/bin/sh
        # Fake claude shim used by KernelHarnessClaudeCodeTests.
        for arg in "$@"; do
            if [ "$arg" = "--version" ]; then
                echo "2.1.999 (Fake)"
                exit 0
            fi
        done
        # Drain stdin so pipes close cleanly, then emit the fixture.
        cat > /dev/null
        cat "\(fixture.path)"
        """
        try script.write(to: versionScript, atomically: true, encoding: .utf8)

        let attrs: [FileAttributeKey: Any] = [.posixPermissions: 0o755]
        try FileManager.default.setAttributes(attrs, ofItemAtPath: versionScript.path)

        self.directory = dir
        self.path = versionScript.path
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: directory)
    }
}
