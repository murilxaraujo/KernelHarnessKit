import Foundation
import KernelHarnessKit

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

