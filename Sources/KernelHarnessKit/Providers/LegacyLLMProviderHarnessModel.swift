import Foundation

/// Adapter that lets the pre-Xcode-27 ``LLMProvider`` API participate in the
/// newer harness-model execution path.
///
/// Keep this as a compatibility shim while new model integrations target
/// ``HarnessModel`` directly or through an Apple FoundationModels adapter.
public struct LegacyLLMProviderHarnessModel: HarnessModel {
    public let provider: any LLMProvider
    public let capabilities: HarnessModelCapabilities

    public init(
        provider: any LLMProvider,
        capabilities: HarnessModelCapabilities = .unknown
    ) {
        self.provider = provider
        self.capabilities = capabilities
    }

    public func streamTurn(
        messages: [ConversationMessage],
        tools: [[String: Any]]?,
        options: HarnessGenerationOptions
    ) -> AsyncThrowingStream<HarnessModelEvent, Error> {
        let stream = provider.streamChat(
            model: strippingVendorPrefix(options.model),
            messages: messages,
            systemPrompt: options.systemPrompt,
            tools: tools,
            responseFormat: options.responseFormat,
            temperature: options.temperature,
            maxTokens: options.maximumResponseTokens
        )

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in stream {
                        switch chunk {
                        case .textDelta(let text):
                            continuation.yield(.textDelta(text))
                        case .toolCallDelta(let index, let id, let name, let argumentsChunk):
                            continuation.yield(.toolCallDelta(
                                index: index,
                                id: id,
                                name: name,
                                argumentsChunk: argumentsChunk
                            ))
                        case .messageComplete(let message, let usage):
                            continuation.yield(.messageComplete(message, usage))
                        case .retry(let attempt, let delay, let reason):
                            continuation.yield(.retry(attempt: attempt, delay: delay, reason: reason))
                        }
                    }
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Placeholder provider used only to preserve the historic non-optional
/// ``QueryContext/provider`` property for model-first contexts.
struct UnavailableLLMProvider: LLMProvider {
    func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: AgentError.noFinalMessage)
        }
    }
}

/// Strip a `vendor/` prefix from a model identifier. Legacy providers are
/// already routed by the time they receive the model id.
func strippingVendorPrefix(_ model: String) -> String {
    if let slash = model.firstIndex(of: "/") {
        return String(model[model.index(after: slash)...])
    }
    return model
}
