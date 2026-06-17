import Foundation

/// Model capabilities the harness can use when deciding which execution path
/// or phase options to enable.
///
/// This mirrors the capability vocabulary introduced by Apple's
/// FoundationModels `LanguageModelCapabilities` without importing that
/// framework from the cross-platform core target.
public struct HarnessModelCapabilities: Sendable, Hashable {
    public var supportsVision: Bool
    public var supportsGuidedGeneration: Bool
    public var supportsReasoning: Bool
    public var supportsToolCalling: Bool

    public init(
        supportsVision: Bool = false,
        supportsGuidedGeneration: Bool = false,
        supportsReasoning: Bool = false,
        supportsToolCalling: Bool = false
    ) {
        self.supportsVision = supportsVision
        self.supportsGuidedGeneration = supportsGuidedGeneration
        self.supportsReasoning = supportsReasoning
        self.supportsToolCalling = supportsToolCalling
    }

    public static let unknown = HarnessModelCapabilities()
}

/// Reasoning effort requested from a model, when supported.
public enum HarnessReasoningLevel: Sendable, Hashable {
    case light
    case moderate
    case deep
    case custom(String)
}

/// Tool-calling behavior requested from a model, when supported.
public enum HarnessToolCallingMode: Sendable, Hashable {
    case allowed
    case required
    case disallowed
}

/// Per-turn model options used by the harness core.
///
/// The shape intentionally maps to FoundationModels `GenerationOptions` and
/// `ContextOptions` (`temperature`, `maximumResponseTokens`, reasoning level,
/// tool-calling mode, schema-in-prompt policy) while remaining usable on Linux
/// and by legacy OpenAI-compatible providers.
public struct HarnessGenerationOptions: Sendable, Hashable {
    public var model: String
    public var systemPrompt: String?
    public var responseFormat: ResponseFormat?
    public var temperature: Double?
    public var maximumResponseTokens: Int?
    public var reasoningLevel: HarnessReasoningLevel?
    public var toolCallingMode: HarnessToolCallingMode?
    public var includeSchemaInPrompt: Bool?
    public var metadata: [String: JSONValue]

    public init(
        model: String,
        systemPrompt: String? = nil,
        responseFormat: ResponseFormat? = nil,
        temperature: Double? = nil,
        maximumResponseTokens: Int? = nil,
        reasoningLevel: HarnessReasoningLevel? = nil,
        toolCallingMode: HarnessToolCallingMode? = nil,
        includeSchemaInPrompt: Bool? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.responseFormat = responseFormat
        self.temperature = temperature
        self.maximumResponseTokens = maximumResponseTokens
        self.reasoningLevel = reasoningLevel
        self.toolCallingMode = toolCallingMode
        self.includeSchemaInPrompt = includeSchemaInPrompt
        self.metadata = metadata
    }
}

/// Streaming events emitted by a model turn.
public enum HarnessModelEvent: Sendable {
    case textDelta(String)
    case toolCallDelta(index: Int, id: String?, name: String?, argumentsChunk: String?)
    case messageComplete(ConversationMessage, UsageSnapshot)
    case metadata([String: JSONValue])
    case retry(attempt: Int, delay: TimeInterval, reason: String)
}

/// Cross-platform model facade consumed by the harness engine.
///
/// New integrations should target this protocol. Apple FoundationModels
/// adapters can live in a separate Apple-only target and wrap any
/// `LanguageModelSession`; server/Linux integrations can continue to adapt
/// existing provider SDKs.
public protocol HarnessModel: Sendable {
    var capabilities: HarnessModelCapabilities { get }

    func streamTurn(
        messages: [ConversationMessage],
        tools: [[String: Any]]?,
        options: HarnessGenerationOptions
    ) -> AsyncThrowingStream<HarnessModelEvent, Error>
}

public extension HarnessModel {
    var capabilities: HarnessModelCapabilities { .unknown }
}
