import Foundation
import KernelHarnessKit

#if canImport(FoundationModels)
import FoundationModels

/// Harness adapter for Apple's Xcode 27 FoundationModels framework.
///
/// This type lets KernelHarnessKit focus on deterministic workflow,
/// workspace, permission, and orchestration concerns while Apple's
/// `LanguageModelSession` performs optimized model execution for any
/// `LanguageModel` implementation: system model, Private Cloud Compute,
/// Core AI, MLX, or provider packages such as Claude/Gemini when available.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public struct FoundationLanguageModelHarnessModel<Model: LanguageModel>: HarnessModel {
    public let model: Model
    public let capabilities: HarnessModelCapabilities

    public init(_ model: Model) {
        self.model = model
        self.capabilities = HarnessModelCapabilities(model.capabilities)
    }

    public func streamTurn(
        messages: [ConversationMessage],
        tools: [[String: Any]]?,
        options: HarnessGenerationOptions
    ) -> AsyncThrowingStream<HarnessModelEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let session = makeSession(systemPrompt: options.systemPrompt)
                    let prompt = latestPromptText(from: messages)
                    let generationOptions = GenerationOptions(
                        temperature: options.temperature,
                        maximumResponseTokens: options.maximumResponseTokens,
                        toolCallingMode: options.toolCallingMode.map(GenerationOptions.ToolCallingMode.init)
                    )
                    let contextOptions = ContextOptions(
                        includeSchemaInPrompt: options.includeSchemaInPrompt,
                        reasoningLevel: options.reasoningLevel.map(ContextOptions.ReasoningLevel.init)
                    )
                    let metadata = options.metadata.foundationModelsMetadata

                    let stream = session.streamResponse(
                        to: prompt,
                        options: generationOptions,
                        contextOptions: contextOptions,
                        metadata: metadata
                    )

                    var previous = ""
                    var latest = ""
                    var latestUsage = UsageSnapshot()
                    for try await snapshot in stream {
                        latest = String(describing: snapshot.content)
                        if latest.hasPrefix(previous) {
                            let delta = String(latest.dropFirst(previous.count))
                            if !delta.isEmpty { continuation.yield(.textDelta(delta)) }
                        } else if !latest.isEmpty {
                            continuation.yield(.textDelta(latest))
                        }
                        previous = latest
                        latestUsage = UsageSnapshot(
                            promptTokens: snapshot.usage.input.totalTokenCount,
                            completionTokens: snapshot.usage.output.totalTokenCount
                        )
                    }

                    continuation.yield(.messageComplete(
                        ConversationMessage(role: .assistant, text: latest),
                        latestUsage
                    ))
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

    private func makeSession(systemPrompt: String?) -> LanguageModelSession {
        if let systemPrompt, !systemPrompt.isEmpty {
            LanguageModelSession(model: model) {
                systemPrompt
            }
        } else {
            LanguageModelSession(model: model)
        }
    }

    private func latestPromptText(from messages: [ConversationMessage]) -> String {
        messages.last(where: { $0.role == .user })?.plainText ?? messages.last?.plainText ?? ""
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
public extension HarnessModelCapabilities {
    init(_ capabilities: LanguageModelCapabilities) {
        self.init(
            supportsVision: capabilities.contains(.vision),
            supportsGuidedGeneration: capabilities.contains(.guidedGeneration),
            supportsReasoning: capabilities.contains(.reasoning),
            supportsToolCalling: capabilities.contains(.toolCalling)
        )
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private extension ContextOptions.ReasoningLevel {
    init(_ level: HarnessReasoningLevel) {
        switch level {
        case .light: self = .light
        case .moderate: self = .moderate
        case .deep: self = .deep
        case .custom(let value): self = .custom(value)
        }
    }
}

@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
@available(tvOS, unavailable)
private extension GenerationOptions.ToolCallingMode {
    init(_ mode: HarnessToolCallingMode) {
        switch mode {
        case .allowed: self = .allowed
        case .required: self = .required
        case .disallowed: self = .disallowed
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var foundationModelsMetadata: [String: any Sendable & Codable & Equatable] {
        var output: [String: any Sendable & Codable & Equatable] = [:]
        for (key, value) in self {
            switch value {
            case .string(let string): output[key] = string
            case .number(let number): output[key] = number
            case .integer(let integer): output[key] = integer
            case .bool(let bool): output[key] = bool
            case .null, .array, .object: break
            }
        }
        return output
    }
}

#endif
