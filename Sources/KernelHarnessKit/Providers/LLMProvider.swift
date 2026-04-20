import Foundation

/// A provider-produced event within a single streaming turn.
public enum StreamChunk: Sendable {
    /// A text delta from the model.
    case textDelta(String)
    /// A partial tool call delta — `index` identifies which parallel call
    /// this delta belongs to within the turn.
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsChunk: String?)
    /// The turn is complete — `message` is the full assistant message and
    /// `usage` is the final usage snapshot.
    case messageComplete(ConversationMessage, UsageSnapshot)
    /// The provider is retrying after a transient failure.
    case retry(attempt: Int, delay: TimeInterval, reason: String)
}

/// Protocol every LLM provider must satisfy.
///
/// Providers translate the provider-agnostic ``ConversationMessage`` and tool
/// schemas into their native wire format, stream the completion back as
/// ``StreamChunk`` events, and normalize the final assistant message back
/// into ``ConversationMessage`` form.
///
/// Implementations must be `Sendable` — the engine holds a provider reference
/// across `TaskGroup` children during sub-agent fan-out.
public protocol LLMProvider: Sendable {
    /// Stream a chat completion.
    ///
    /// - Parameters:
    ///   - model: Provider-specific model identifier *without* the
    ///     `vendor/` prefix used by ``ProviderRegistry``.
    ///   - messages: Full conversation history, ordered oldest-first.
    ///   - systemPrompt: Optional system prompt.
    ///   - tools: Tool schemas to advertise to the model, in OpenAI function
    ///     format (`{ type: "function", function: { name, description, parameters } }`).
    ///   - responseFormat: The requested response format.
    ///   - temperature: Sampling temperature. `nil` uses provider default.
    ///   - maxTokens: Maximum tokens in the completion.
    func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error>
}
