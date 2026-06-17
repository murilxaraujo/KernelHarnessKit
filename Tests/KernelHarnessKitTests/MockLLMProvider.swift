import Foundation
@testable import KernelHarnessKit

/// A scripted LLM provider for deterministic tests.
///
/// Usage:
///
/// ```swift
/// let provider = MockLLMProvider(script: [
///     .response(text: "let me look it up", toolCalls: [
///         .init(id: "t1", name: "read_file", input: ["path": "x.md"])
///     ]),
///     .response(text: "final answer"),
/// ])
/// ```
///
/// Each call to ``streamChat`` consumes the next scripted response. When the
/// script is exhausted, the provider emits an empty assistant message to end
/// the loop.
final class MockLLMProvider: LLMProvider, HarnessModel, @unchecked Sendable {
    struct ToolCall: Sendable {
        let id: String
        let name: String
        let input: [String: JSONValue]
    }

    struct Response: Sendable {
        let text: String
        let toolCalls: [ToolCall]
        let usage: UsageSnapshot?
        let textChunks: [String]?

        static func response(
            text: String = "",
            toolCalls: [ToolCall] = [],
            usage: UsageSnapshot? = UsageSnapshot(promptTokens: 10, completionTokens: 5),
            textChunks: [String]? = nil
        ) -> Response {
            Response(text: text, toolCalls: toolCalls, usage: usage, textChunks: textChunks)
        }
    }

    private let script: [Response]
    private let cursor: CallCounter

    /// Log of every prompt the mock has been asked to stream.
    var requests: [(model: String, messages: [ConversationMessage])] {
        cursor.requests
    }

    init(script: [Response]) {
        self.script = script
        self.cursor = CallCounter()
    }

    func streamTurn(
        messages: [ConversationMessage],
        tools: [[String: Any]]?,
        options: HarnessGenerationOptions
    ) -> AsyncThrowingStream<HarnessModelEvent, Error> {
        let stream = streamChat(
            model: strippingVendorPrefix(options.model),
            messages: messages,
            systemPrompt: options.systemPrompt,
            tools: tools,
            responseFormat: options.responseFormat,
            temperature: options.temperature,
            maxTokens: options.maximumResponseTokens
        )
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    for try await chunk in stream {
                        switch chunk {
                        case .textDelta(let text): continuation.yield(.textDelta(text))
                        case .toolCallDelta(let index, let id, let name, let argumentsChunk):
                            continuation.yield(.toolCallDelta(index: index, id: id, name: name, argumentsChunk: argumentsChunk))
                        case .messageComplete(let message, let usage): continuation.yield(.messageComplete(message, usage))
                        case .retry(let attempt, let delay, let reason): continuation.yield(.retry(attempt: attempt, delay: delay, reason: reason))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        let index = cursor.next()
        cursor.record(model: model, messages: messages)
        let response = index < script.count ? script[index] : Response(
            text: "",
            toolCalls: [],
            usage: UsageSnapshot(),
            textChunks: nil
        )
        return AsyncThrowingStream { continuation in
            Task {
                for chunk in response.textChunks ?? [response.text] {
                    if !chunk.isEmpty {
                        continuation.yield(.textDelta(chunk))
                    }
                }
                var content: [ContentBlock] = []
                if !response.text.isEmpty {
                    content.append(.text(response.text))
                }
                for call in response.toolCalls {
                    content.append(.toolUse(id: call.id, name: call.name, input: call.input))
                }
                let message = ConversationMessage(role: .assistant, content: content)
                continuation.yield(.messageComplete(message, response.usage ?? UsageSnapshot()))
                continuation.finish()
            }
        }
    }

    /// Thread-safe call counter + request log.
    final class CallCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var _requests: [(model: String, messages: [ConversationMessage])] = []

        var requests: [(model: String, messages: [ConversationMessage])] {
            lock.lock(); defer { lock.unlock() }
            return _requests
        }

        func next() -> Int {
            lock.lock(); defer { lock.unlock() }
            let current = count
            count += 1
            return current
        }

        func record(model: String, messages: [ConversationMessage]) {
            lock.lock(); defer { lock.unlock() }
            _requests.append((model, messages))
        }
    }
}
