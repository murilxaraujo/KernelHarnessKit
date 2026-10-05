import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("HarnessEngine")
struct HarnessEngineTests {
    private func makeContext(workspace: any WorkspaceProvider = InMemoryWorkspace()) -> HarnessContext {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        return HarnessContext(
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: workspace
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
            context: makeContext(workspace: workspace)
        )

        var events: [AgentEvent] = []
        for try await event in engine.run() { events.append(event) }
        #expect(events.contains(where: { if case .harnessComplete = $0 { return true } else { return false } }))
        #expect(try await workspace.readFile(path: "prepared.txt") == "ready")
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
            context: makeContext(workspace: workspace)
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
        let registry = ToolRegistry()

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

        let engine = HarnessEngine(
            definition: definition,
            context: HarnessContext(
                toolRegistry: registry,
                permissionChecker: DefaultPermissionChecker(mode: .auto),
                workspace: workspace
            )
        )

        for try await _ in engine.run() {}
        let content = try await workspace.readFile(path: "merged.txt")
        #expect(content.contains("1:"))
        #expect(content.contains("2:"))
        #expect(!content.contains("error:"))
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
                toolRegistry: ToolRegistry(),
                permissionChecker: DefaultPermissionChecker(mode: .auto),
                workspace: workspace,
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
            context: makeContext()
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
            context: makeContext(workspace: workspace)
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
            context: makeContext()
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
            context: makeContext(workspace: workspace)
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
            context: makeContext()
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
