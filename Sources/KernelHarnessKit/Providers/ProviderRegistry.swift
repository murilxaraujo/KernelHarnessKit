import Foundation

/// Maps a `vendor/` prefix on a model identifier to an ``LLMProvider``
/// instance.
///
/// Consumers that speak multiple vendors' OpenAI-compatible endpoints
/// register one ``OpenAICompatibleProvider`` per vendor and then pass model
/// identifiers like `"openai/gpt-4o"` or `"anthropic/claude-sonnet-4-5"` to
/// the engine. The registry strips the prefix and hands off to the matching
/// provider; the provider sees the bare model id.
///
/// ```swift
/// let registry = ProviderRegistry(providers: [
///     "openai": OpenAICompatibleProvider(apiKey: "..."),
///     "anthropic": .anthropic(apiKey: "..."),
///     "google": .google(apiKey: "..."),
/// ])
/// let provider = registry.provider(for: "anthropic/claude-sonnet-4-5")
/// ```
public struct ProviderRegistry: Sendable {
    private let providers: [String: any LLMProvider]
    private let fallbackKey: String?

    /// Construct a registry.
    ///
    /// - Parameters:
    ///   - providers: Mapping from vendor prefix (without trailing `/`) to provider.
    ///   - fallback: Vendor prefix used when a model identifier has no prefix.
    ///     Defaults to `"openai"`.
    public init(providers: [String: any LLMProvider], fallback: String? = "openai") {
        self.providers = providers
        self.fallbackKey = fallback
    }

    /// Return the provider that should handle a given model identifier.
    ///
    /// - Parameter modelId: Model identifier, optionally prefixed with
    ///   `vendor/` (e.g., `"anthropic/claude-sonnet-4-5"`).
    /// - Returns: The matching provider, or the fallback if no prefix
    ///   matches. Returns `nil` only if the fallback is not configured
    ///   either.
    public func provider(for modelId: String) -> (any LLMProvider)? {
        if let slash = modelId.firstIndex(of: "/") {
            let prefix = String(modelId[..<slash])
            if let provider = providers[prefix] { return provider }
        }
        if let fallbackKey, let provider = providers[fallbackKey] {
            return provider
        }
        return nil
    }

    /// All configured vendor prefixes.
    public var vendors: [String] { Array(providers.keys) }
}

// MARK: - Vendor presets

extension OpenAICompatibleProvider {
    /// Preset for OpenAI's public endpoint (`https://api.openai.com/v1`).
    public static func openai(
        apiKey: String,
        organization: String? = nil
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: apiKey, organization: organization)
    }

    /// Preset for Anthropic's OpenAI-compatible endpoint
    /// (`https://api.anthropic.com/v1`).
    public static func anthropic(apiKey: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: URL(string: "https://api.anthropic.com/v1")!
        )
    }

    /// Preset for Google Gemini's OpenAI-compatible endpoint
    /// (`https://generativelanguage.googleapis.com/v1beta/openai`).
    public static func google(apiKey: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: URL(string: "https://generativelanguage.googleapis.com/v1beta/openai")!
        )
    }

    /// Preset for Groq's OpenAI-compatible endpoint
    /// (`https://api.groq.com/openai/v1`).
    public static func groq(apiKey: String) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            apiKey: apiKey,
            baseURL: URL(string: "https://api.groq.com/openai/v1")!
        )
    }

    /// Preset for a local vLLM/Ollama-style endpoint. Defaults to
    /// `http://localhost:11434/v1` (Ollama's default).
    public static func local(
        baseURL: URL = URL(string: "http://localhost:11434/v1")!,
        apiKey: String = "ollama"
    ) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(apiKey: apiKey, baseURL: baseURL)
    }
}
