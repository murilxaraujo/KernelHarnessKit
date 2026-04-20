import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("ProviderRegistry")
struct ProviderRegistryTests {
    @Test func routesByPrefix() {
        let openAI = MockLLMProvider(script: [])
        let anthropic = MockLLMProvider(script: [])
        let registry = ProviderRegistry(
            providers: [
                "openai": openAI,
                "anthropic": anthropic,
            ],
            fallback: "openai"
        )
        #expect(registry.provider(for: "anthropic/claude-sonnet-4-5") as? MockLLMProvider === anthropic)
        #expect(registry.provider(for: "openai/gpt-4o") as? MockLLMProvider === openAI)
    }

    @Test func fallsBackWhenPrefixUnknown() {
        let openAI = MockLLMProvider(script: [])
        let registry = ProviderRegistry(providers: ["openai": openAI], fallback: "openai")
        #expect(registry.provider(for: "gpt-4o-mini") as? MockLLMProvider === openAI)
        #expect(registry.provider(for: "unknown/bar") as? MockLLMProvider === openAI)
    }

    @Test func nilWhenNoFallback() {
        let openAI = MockLLMProvider(script: [])
        let registry = ProviderRegistry(providers: ["openai": openAI], fallback: nil)
        #expect(registry.provider(for: "bogus/thing") == nil)
    }
}
