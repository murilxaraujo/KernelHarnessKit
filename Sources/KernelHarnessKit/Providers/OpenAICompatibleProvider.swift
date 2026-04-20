import Foundation
import OpenAI

/// A provider that speaks any OpenAI-compatible chat completions endpoint.
///
/// This is the primary provider shipped with KernelHarnessKit. Because
/// Anthropic, Google, DeepSeek, Groq, xAI, OpenRouter, and local runtimes
/// (Ollama, LM Studio, vLLM) all expose OpenAI-compatible endpoints, a single
/// implementation — configured with the vendor's base URL and key — is
/// enough for the majority of use cases.
///
/// Construct one instance per vendor and register them with
/// ``ProviderRegistry`` keyed by a `vendor/` prefix on the model identifier:
///
/// ```swift
/// let registry = ProviderRegistry(providers: [
///     "openai":    .openai(apiKey: env("OPENAI_API_KEY")),
///     "anthropic": .anthropic(apiKey: env("ANTHROPIC_API_KEY")),
///     "google":    .google(apiKey: env("GOOGLE_AI_API_KEY")),
/// ])
/// ```
public struct OpenAICompatibleProvider: LLMProvider {
    /// The underlying MacPaw OpenAI client. Exposed for advanced consumers
    /// that need to drive it directly.
    public let client: OpenAI

    /// Default sampling temperature, used when the caller doesn't override.
    public let defaultTemperature: Double?

    /// Whether to request parallel tool calls from the model. OpenAI and
    /// compatible vendors accept this; Anthropic's OpenAI-compat endpoint
    /// ignores it but doesn't error.
    public let parallelToolCalls: Bool?

    /// Construct a provider.
    ///
    /// - Parameters:
    ///   - apiKey: The vendor API key. Pass `nil` when relying on a proxy
    ///     that injects auth (see MacPaw's documentation).
    ///   - baseURL: The vendor's OpenAI-compatible base URL. Must include
    ///     the path prefix (typically `/v1`). Defaults to OpenAI's endpoint.
    ///   - organization: Optional `OpenAI-Organization` header value.
    ///   - timeoutInterval: Per-request timeout. Defaults to 120s.
    ///   - customHeaders: Extra headers to include on every request.
    ///   - defaultTemperature: Sampling temperature used when a call doesn't
    ///     override.
    ///   - parallelToolCalls: Whether to request parallel tool calls.
    public init(
        apiKey: String?,
        baseURL: URL = URL(string: "https://api.openai.com/v1")!,
        organization: String? = nil,
        timeoutInterval: TimeInterval = 120,
        customHeaders: [String: String] = [:],
        defaultTemperature: Double? = nil,
        parallelToolCalls: Bool? = true
    ) {
        let host = baseURL.host ?? "api.openai.com"
        let port = baseURL.port ?? (baseURL.scheme == "http" ? 80 : 443)
        let scheme = baseURL.scheme ?? "https"
        let basePath = baseURL.path.isEmpty ? "/v1" : baseURL.path
        let config = OpenAI.Configuration(
            token: apiKey,
            organizationIdentifier: organization,
            host: host,
            port: port,
            scheme: scheme,
            basePath: basePath,
            timeoutInterval: timeoutInterval,
            customHeaders: customHeaders
        )
        self.client = OpenAI(configuration: config)
        self.defaultTemperature = defaultTemperature
        self.parallelToolCalls = parallelToolCalls
    }

    public func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        // Convert the non-Sendable [[String: Any]] tools into MacPaw's
        // strongly-typed ChatCompletionToolParam up front so the async Task
        // below only captures Sendable values.
        let preparedQuery: ChatQuery
        do {
            preparedQuery = try buildQuery(
                model: model,
                messages: messages,
                systemPrompt: systemPrompt,
                tools: tools,
                responseFormat: responseFormat,
                temperature: temperature ?? self.defaultTemperature,
                maxTokens: maxTokens
            )
        } catch {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: error)
            }
        }

        let client = self.client
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let query = preparedQuery
                    var textAccumulator = ""
                    let toolAccumulator = ToolCallAccumulator()
                    var finishReason: String? = nil
                    var usage: UsageSnapshot? = nil

                    let stream: AsyncThrowingStream<ChatStreamResult, Error>
                        = client.chatsStream(query: query)
                    for try await result in stream {
                        try Task.checkCancellation()
                        if let u = result.usage {
                            usage = UsageSnapshot(
                                promptTokens: u.promptTokens,
                                completionTokens: u.completionTokens
                            )
                        }
                        for choice in result.choices {
                            let delta = choice.delta
                            if let content = delta.content, !content.isEmpty {
                                textAccumulator.append(content)
                                continuation.yield(.textDelta(content))
                            }
                            if let toolCalls = delta.toolCalls {
                                for call in toolCalls {
                                    await toolAccumulator.apply(call)
                                    continuation.yield(.toolCallDelta(
                                        index: call.index ?? 0,
                                        id: call.id,
                                        name: call.function?.name,
                                        argumentsChunk: call.function?.arguments
                                    ))
                                }
                            }
                            if let reason = choice.finishReason {
                                finishReason = reason.rawValue
                            }
                        }
                    }

                    let toolUses = await toolAccumulator.build()
                    var content: [ContentBlock] = []
                    if !textAccumulator.isEmpty {
                        content.append(.text(textAccumulator))
                    }
                    for call in toolUses {
                        content.append(.toolUse(
                            id: call.id,
                            name: call.name,
                            input: call.input
                        ))
                    }
                    let message = ConversationMessage(role: .assistant, content: content)
                    continuation.yield(.messageComplete(message, usage ?? UsageSnapshot()))
                    continuation.finish()
                    _ = finishReason  // reserved for future use (stop vs length)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Query construction

    private func buildQuery(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) throws -> ChatQuery {
        let converted = try convertMessages(messages, systemPrompt: systemPrompt)
        let mappedTools = try mapTools(tools)
        let mappedResponseFormat = try mapResponseFormat(responseFormat)

        return ChatQuery(
            messages: converted,
            model: model,
            maxCompletionTokens: maxTokens,
            parallelToolCalls: tools == nil ? nil : parallelToolCalls,
            responseFormat: mappedResponseFormat,
            temperature: temperature,
            tools: mappedTools,
            stream: true,
            streamOptions: .init(includeUsage: true)
        )
    }
}

// MARK: - Message conversion

private func convertMessages(
    _ messages: [ConversationMessage],
    systemPrompt: String?
) throws -> [ChatQuery.ChatCompletionMessageParam] {
    var result: [ChatQuery.ChatCompletionMessageParam] = []
    if let systemPrompt, !systemPrompt.isEmpty {
        result.append(.system(.init(content: .textContent(systemPrompt))))
    }

    for message in messages {
        switch message.role {
        case .system:
            let text = message.plainText
            result.append(.system(.init(content: .textContent(text))))

        case .user:
            result.append(.user(.init(content: .string(message.plainText))))

        case .assistant:
            let text = message.plainText
            let toolCalls = message.content.compactMap(toolCallParam(from:))
            result.append(.assistant(.init(
                content: text.isEmpty ? nil : .textContent(text),
                toolCalls: toolCalls.isEmpty ? nil : toolCalls
            )))

        case .tool:
            for block in message.content {
                if case let .toolResult(toolUseId, content, _) = block {
                    result.append(.tool(.init(
                        content: .textContent(content),
                        toolCallId: toolUseId
                    )))
                }
            }
        }
    }
    return result
}

private func toolCallParam(
    from block: ContentBlock
) -> ChatQuery.ChatCompletionMessageParam.AssistantMessageParam.ToolCallParam? {
    guard case let .toolUse(id, name, input) = block else { return nil }
    let args = (try? JSONEncoder().encode(input))
        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return .init(id: id, function: .init(arguments: args, name: name))
}

// MARK: - Tool schema mapping

private func mapTools(
    _ tools: [[String: Any]]?
) throws -> [ChatQuery.ChatCompletionToolParam]? {
    guard let tools, !tools.isEmpty else { return nil }
    // Round-trip through Codable — MacPaw's ChatCompletionToolParam decodes
    // the same OpenAI function-calling JSON shape we emit via AnyTool.apiSchema.
    let data = try JSONSerialization.data(withJSONObject: tools)
    return try JSONDecoder().decode([ChatQuery.ChatCompletionToolParam].self, from: data)
}

// MARK: - Response format

private func mapResponseFormat(_ format: ResponseFormat?) throws -> ChatQuery.ResponseFormat? {
    guard let format else { return nil }
    switch format {
    case .text:
        return .text
    case .jsonObject:
        return .jsonObject
    case .jsonSchema(let name, let schema, let strict):
        // Round-trip through JSONSchemaDefinition's Codable so the server
        // receives the exact schema we produced.
        let envelope: [String: Any] = [
            "name": name,
            "schema": (try JSONValue(encoding: schema)).foundationValue,
            "strict": strict,
        ]
        let data = try JSONSerialization.data(withJSONObject: envelope)
        let options = try JSONDecoder().decode(
            ChatQuery.StructuredOutputConfigurationOptions.self,
            from: data
        )
        return .jsonSchema(options)
    }
}

// MARK: - Tool call accumulator

private actor ToolCallAccumulator {
    private var byIndex: [Int: Fragment] = [:]

    struct Fragment {
        var id: String?
        var name: String?
        var arguments: String
    }

    func apply(_ delta: ChatStreamResult.Choice.ChoiceDelta.ChoiceDeltaToolCall) {
        let idx = delta.index ?? 0
        var fragment = byIndex[idx] ?? Fragment(id: nil, name: nil, arguments: "")
        if let id = delta.id { fragment.id = id }
        if let function = delta.function {
            if let name = function.name { fragment.name = name }
            if let args = function.arguments { fragment.arguments.append(args) }
        }
        byIndex[idx] = fragment
    }

    func build() -> [(id: String, name: String, input: [String: JSONValue])] {
        byIndex.keys.sorted().compactMap { idx in
            let fragment = byIndex[idx]!
            guard let id = fragment.id, let name = fragment.name else { return nil }
            let parsed: [String: JSONValue]
            let trimmed = fragment.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                parsed = [:]
            } else if
                let data = trimmed.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([String: JSONValue].self, from: data)
            {
                parsed = decoded
            } else {
                parsed = [:]
            }
            return (id, name, parsed)
        }
    }
}

// MARK: - Utilities


