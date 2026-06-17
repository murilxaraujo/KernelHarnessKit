import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("HarnessEngine")
struct HarnessEngineTests {
    private func makeContext(harnessModel: any HarnessModel, workspace: any WorkspaceProvider = InMemoryWorkspace()) -> HarnessContext {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        return HarnessContext(
            harnessModel: harnessModel,
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: workspace,
            model: "gpt-4o"
        )
    }

    @Test func runsProgrammaticPhase() async throws {
        let workspace = InMemoryWorkspace()
        let phase = PhaseDefinition(
            name: "prepare",
            description: "prepare the data",
            systemPrompt: "",
            workspaceOutput: "prepared.txt",
            execution: .programmatic { _ in "ready" }
        )
        let definition = HarnessDefinition(
            type: "prep",
            displayName: "Prep",
            description: "prep test",
            phases: [phase]
        )
        let engine = HarnessEngine(
            definition: definition,
            context: makeContext(harnessModel: MockLLMProvider(script: []), workspace: workspace)
        )

        var events: [AgentEvent] = []
        for try await event in engine.run() { events.append(event) }
        #expect(events.contains(where: { if case .harnessComplete = $0 { return true } else { return false } }))
        #expect(try await workspace.readFile(path: "prepared.txt") == "ready")
    }

    @Test func runsLLMSinglePhase() async throws {
        let workspace = InMemoryWorkspace()
        let provider = MockLLMProvider(script: [.response(text: "summary goes here")])
        let phase = PhaseDefinition(
            name: "summarize",
            description: "summarize",
            systemPrompt: "you are a summarizer",
            workspaceOutput: "summary.md",
            execution: .llmSingle(promptBuilder: { _ in "summarize x" }, responseFormat: nil)
        )
        let definition = HarnessDefinition(type: "s", displayName: "S", description: "", phases: [phase])
        let engine = HarnessEngine(
            definition: definition,
            context: makeContext(harnessModel: provider, workspace: workspace)
        )
        for try await _ in engine.run() {}
        #expect(try await workspace.readFile(path: "summary.md") == "summary goes here")
    }

    @Test func runsLLMAgentPhase() async throws {
        let workspace = InMemoryWorkspace()
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "write_file", input: ["path": "note.md", "content": "hi"])
            ]),
            .response(text: "all done"),
        ])
        let phase = PhaseDefinition(
            name: "work",
            description: "",
            systemPrompt: "",
            tools: ["write_file"],
            workspaceOutput: "result.txt",
            execution: .llmAgent(promptBuilder: { _ in "do the task" }, maxTurns: 5)
        )
        let definition = HarnessDefinition(type: "w", displayName: "W", description: "", phases: [phase])
        let engine = HarnessEngine(
            definition: definition,
            context: makeContext(harnessModel: provider, workspace: workspace)
        )
        for try await _ in engine.run() {}
        #expect(try await workspace.readFile(path: "note.md") == "hi")
        #expect(try await workspace.readFile(path: "result.txt") == "all done")
    }

    @Test func emitsPhaseLifecycle() async throws {
        let workspace = InMemoryWorkspace()
        let p1 = PhaseDefinition(
            name: "a", description: "", systemPrompt: "",
            workspaceOutput: "a.txt",
            execution: .programmatic { _ in "one" }
        )
        let p2 = PhaseDefinition(
            name: "b", description: "", systemPrompt: "",
            workspaceOutput: "b.txt",
            execution: .programmatic { _ in "two" }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "t", displayName: "t", description: "", phases: [p1, p2]),
            context: makeContext(harnessModel: MockLLMProvider(script: []), workspace: workspace)
        )

        var phaseStarts: [String] = []
        var phaseCompletes: [String] = []
        for try await event in engine.run() {
            switch event {
            case .harnessPhaseStart(let name, _, _): phaseStarts.append(name)
            case .harnessPhaseComplete(let name, _): phaseCompletes.append(name)
            default: break
            }
        }
        #expect(phaseStarts == ["a", "b"])
        #expect(phaseCompletes == ["a", "b"])
    }

    @Test func runsBatchPhase() async throws {
        let items = [
            PhaseBatchItem(id: "1", content: "alpha"),
            PhaseBatchItem(id: "2", content: "beta"),
        ]
        let workspace = InMemoryWorkspace()
        let providerBox = ProviderFactoryBox()
        let registry = ToolRegistry()

        // Use a factory-backed LLMProvider that returns per-item unique
        // responses. Since the engine creates one SubAgentExecutor per item
        // via the BatchExecutor, each needs its own provider.
        let phase = PhaseDefinition(
            name: "batch",
            description: "",
            systemPrompt: "",
            workspaceOutput: "merged.txt",
            execution: .llmBatchAgents(
                concurrency: 2,
                itemsLoader: { _ in items },
                itemPromptBuilder: { "analyze \($0.content)" },
                maxTurnsPerItem: 2,
                resultFormatter: { results in
                    results.map { "\($0.item.id):\($0.output)" }.joined(separator: "\n")
                }
            )
        )
        let definition = HarnessDefinition(type: "bt", displayName: "bt", description: "", phases: [phase])

        // Construct a HarnessContext whose provider is a distinct one per call
        // via a closure wrapper. The engine uses HarnessContext.provider
        // directly in the sub-agent factory, so we wrap MockLLMProvider to
        // hand out unique responses.
        let sharedProvider = RotatingMockProvider(box: providerBox)
        let engine = HarnessEngine(
            definition: definition,
            context: HarnessContext(
                harnessModel: sharedProvider,
                toolRegistry: registry,
                permissionChecker: DefaultPermissionChecker(mode: .auto),
                workspace: workspace,
                model: "gpt-4o"
            )
        )

        for try await _ in engine.run() {}
        let content = try await workspace.readFile(path: "merged.txt")
        #expect(content.contains("1:answer-"))
        #expect(content.contains("2:answer-"))
    }

    @Test func runsHumanInputPhase() async throws {
        let workspace = InMemoryWorkspace()
        let phase = PhaseDefinition(
            name: "ask", description: "", systemPrompt: "",
            workspaceOutput: "answer.txt",
            execution: .llmHumanInput(questionBuilder: { _ in "what's your name?" })
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "ha", displayName: "", description: "", phases: [phase]),
            context: HarnessContext(
                harnessModel: MockLLMProvider(script: []),
                toolRegistry: ToolRegistry(),
                permissionChecker: DefaultPermissionChecker(mode: .auto),
                workspace: workspace,
                model: "gpt-4o",
                askUserHandler: StaticAskUserHandler(response: "Ada")
            )
        )

        var gotQuestion = false
        for try await event in engine.run() {
            if case .harnessHumanInput(let q) = event {
                gotQuestion = q == "what's your name?"
            }
        }
        #expect(gotQuestion)
        #expect(try await workspace.readFile(path: "answer.txt") == "Ada")
    }

    @Test func failingPhasePropagatesError() async throws {
        struct BoomError: Error {}
        let phase = PhaseDefinition(
            name: "boom", description: "", systemPrompt: "",
            workspaceOutput: nil,
            execution: .programmatic { _ in throw BoomError() }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "b", displayName: "", description: "", phases: [phase]),
            context: makeContext(harnessModel: MockLLMProvider(script: []))
        )

        var errored = false
        var threw = false
        do {
            for try await event in engine.run() {
                if case .harnessPhaseError = event { errored = true }
            }
        } catch {
            threw = true
        }
        #expect(errored)
        #expect(threw)
    }

    @Test func retryPolicyRetriesFailedPhase() async throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func increment() -> Int {
                lock.lock(); defer { lock.unlock() }
                value += 1
                return value
            }
        }
        struct RetryBoom: Error {}
        let counter = Counter()
        let workspace = InMemoryWorkspace()
        let phase = PhaseDefinition(
            name: "flaky", description: "", systemPrompt: "",
            workspaceOutput: "result.txt",
            retryPolicy: PhaseRetryPolicy(maxAttempts: 3, backoff: .milliseconds(1)),
            execution: .programmatic { _ in
                if counter.increment() < 3 { throw RetryBoom() }
                return "ok"
            }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "retry", displayName: "", description: "", phases: [phase]),
            context: makeContext(harnessModel: MockLLMProvider(script: []), workspace: workspace)
        )

        var retryStatuses = 0
        for try await event in engine.run() {
            if case .status(let message) = event, message.contains("Retrying attempt") {
                retryStatuses += 1
            }
        }
        #expect(retryStatuses == 2)
        #expect(try await workspace.readFile(path: "result.txt") == "ok")
    }

    @Test func outputValidationRejectsInvalidOutput() async throws {
        let phase = PhaseDefinition(
            name: "empty", description: "", systemPrompt: "",
            workspaceOutput: "result.txt",
            outputValidation: .nonEmpty,
            execution: .programmatic { _ in "   " }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "validation", displayName: "", description: "", phases: [phase]),
            context: makeContext(harnessModel: MockLLMProvider(script: []))
        )

        var sawPhaseError = false
        do {
            for try await event in engine.run() {
                if case .harnessPhaseError(let name, let error) = event {
                    sawPhaseError = name == "empty" && error.contains("output validation failed")
                }
            }
            Issue.record("Expected validation to throw")
        } catch let error as HarnessError {
            if case .outputValidationFailed(let phase, _) = error {
                #expect(phase == "empty")
            } else {
                Issue.record("Unexpected harness error: \(error)")
            }
        }
        #expect(sawPhaseError)
    }

    @Test func jsonSchemaOutputValidationAcceptsValidOutput() async throws {
        let workspace = InMemoryWorkspace()
        let phase = PhaseDefinition(
            name: "json", description: "", systemPrompt: "",
            workspaceOutput: "result.json",
            outputValidation: .jsonSchema(.object(
                properties: ["summary": .string()],
                required: ["summary"],
                additionalProperties: false
            )),
            execution: .programmatic { _ in #"{"summary":"ok"}"# }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "json", displayName: "", description: "", phases: [phase]),
            context: makeContext(harnessModel: MockLLMProvider(script: []), workspace: workspace)
        )

        for try await _ in engine.run() {}
        #expect(try await workspace.readFile(path: "result.json") == #"{"summary":"ok"}"#)
    }

    @Test func timeoutFires() async throws {
        let phase = PhaseDefinition(
            name: "slow", description: "", systemPrompt: "",
            workspaceOutput: nil,
            timeout: .milliseconds(50),
            execution: .programmatic { _ in
                try await Task.sleep(for: .seconds(1))
                return "should not reach"
            }
        )
        let engine = HarnessEngine(
            definition: HarnessDefinition(type: "t", displayName: "", description: "", phases: [phase]),
            context: makeContext(harnessModel: MockLLMProvider(script: []))
        )

        var threw = false
        do {
            for try await _ in engine.run() {}
        } catch {
            threw = true
        }
        #expect(threw)
    }
}

/// A model that delegates to a fresh MockLLMProvider from a factory on each
/// call — gives each sub-agent in a batch its own scripted reply.
final class RotatingMockProvider: LLMProvider, HarnessModel, @unchecked Sendable {
    let box: ProviderFactoryBox
    init(box: ProviderFactoryBox) { self.box = box }

    func streamTurn(
        messages: [ConversationMessage],
        tools: [[String: Any]]?,
        options: HarnessGenerationOptions
    ) -> AsyncThrowingStream<HarnessModelEvent, Error> {
        box.next().streamTurn(messages: messages, tools: tools, options: options)
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
        box.next().streamChat(
            model: model,
            messages: messages,
            systemPrompt: systemPrompt,
            tools: tools,
            responseFormat: responseFormat,
            temperature: temperature,
            maxTokens: maxTokens
        )
    }
}

struct StaticAskUserHandler: AskUserHandler {
    let response: String
    func askUser(question: String) async throws -> String { response }
}

struct HarnessRegistryTests {
    @Test func registersAndLooksUp() {
        let registry = HarnessRegistry()
        let def = HarnessDefinition(type: "t", displayName: "T", description: "", phases: [])
        registry.register(def)
        #expect(registry.get("t")?.displayName == "T")
        #expect(registry.count == 1)
        #expect(registry.get("other") == nil)
    }
}
