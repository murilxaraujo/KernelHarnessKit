#  Providers

Speaking to every LLM vendor through one OpenAI-compatible surface.

## Overview

KernelHarnessKit talks to the model through the ``LLMProvider`` protocol.
The shipped implementation, ``OpenAICompatibleProvider``, wraps the
[MacPaw/OpenAI](https://github.com/MacPaw/OpenAI) SDK. Because Anthropic,
Google Gemini, DeepSeek, Groq, xAI, OpenRouter, and local runtimes
(vLLM, Ollama, LM Studio) all expose OpenAI-compatible endpoints, **one
provider implementation suffices for the majority of production use
cases**.

### Vendor presets

The framework ships a preset per major vendor:

```swift
let openai    = OpenAICompatibleProvider.openai(apiKey: oaKey)
let anthropic = OpenAICompatibleProvider.anthropic(apiKey: anKey)
let google    = OpenAICompatibleProvider.google(apiKey: gKey)
let groq      = OpenAICompatibleProvider.groq(apiKey: grKey)
let ollama    = OpenAICompatibleProvider.local()  // http://localhost:11434/v1
```

Register them by prefix:

```swift
let registry = ProviderRegistry(providers: [
    "openai":    openai,
    "anthropic": anthropic,
    "google":    google,
    "groq":      groq,
])
```

Use a `vendor/model` syntax when building a ``QueryContext``; the registry
strips the prefix and routes:

```swift
let context = QueryContext(
    provider: registry.provider(for: "anthropic/claude-sonnet-4-5")!,
    // ...
    model: "anthropic/claude-sonnet-4-5"
)
```

### Streaming events

The provider returns an `AsyncThrowingStream<StreamChunk, Error>`.
``StreamChunk`` has four variants:

- ``StreamChunk/textDelta(_:)`` — word-by-word model output.
- ``StreamChunk/toolCallDelta(index:id:name:argumentsChunk:)`` — partial
  tool-call fragments as they arrive (useful for progress UIs).
- ``StreamChunk/messageComplete(_:_:)`` — the final assistant message
  plus usage snapshot.
- ``StreamChunk/retry(attempt:delay:reason:)`` — the provider is retrying
  after a transient error.

The engine consumes these and produces the higher-level ``AgentEvent``
stream consumers subscribe to.

### Custom providers

Any conformance to ``LLMProvider`` works. A `MockLLMProvider` in the test
suite drives the engine offline with scripted responses; consumers
write the same shape when integrating a vendor whose OpenAI-compat
endpoint is missing or too limited.

### Structured output

``QueryContext/responseFormat`` or a phase's `PhaseExecution.llmSingle`
closure can request ``ResponseFormat/jsonSchema(name:schema:strict:)``,
which uses OpenAI's Structured Outputs via `response_format`. Providers
that don't support it are expected to honor ``ResponseFormat/jsonObject``
or fall back to plain text.
