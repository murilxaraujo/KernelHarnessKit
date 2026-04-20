import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("SubAgentExecutor")
struct SubAgentExecutorTests {
    @Test func runsIsolatedAgentLoop() async throws {
        let provider = MockLLMProvider(script: [.response(text: "sub-answer")])
        let registry = ToolRegistry()
        registry.registerBuiltIns()

        let executor = SubAgentExecutor(
            workspace: InMemoryWorkspace(),
            toolRegistry: registry,
            provider: provider,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            config: SubAgentConfig(systemPrompt: "you are a helper", model: "gpt-4o")
        )

        let output = try await executor.run(initialMessage: "ping")
        #expect(output == "sub-answer")
    }

    @Test func stripsTaskAndTodoToolsFromCuratedRegistry() async throws {
        // If the sub-agent tries to invoke `task`, the curated registry should
        // report it as unknown — guarding against recursion.
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "task", input: ["description": "x", "prompt": "y"])
            ]),
            .response(text: "done"),
        ])
        let registry = ToolRegistry()
        registry.registerBuiltIns()

        let executor = SubAgentExecutor(
            workspace: InMemoryWorkspace(),
            toolRegistry: registry,
            provider: provider,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            config: SubAgentConfig(systemPrompt: "", model: "gpt-4o", maxTurns: 3)
        )

        let output = try await executor.run(initialMessage: "try to delegate")
        #expect(output == "done")
        // The second prompt should carry the "unknown tool" result.
        let lastRequest = provider.requests.last
        let lastUserMessage = lastRequest?.messages.last
        let joined = lastUserMessage?.content.reduce(into: "") { acc, block in
            if case .toolResult(_, let content, _) = block { acc.append(content) }
        } ?? ""
        #expect(joined.contains("unknown tool 'task'"))
    }
}

@Suite("BatchExecutor")
struct BatchExecutorTests {
    @Test func processesItemsInParallel() async throws {
        let items = ["alpha", "beta", "gamma", "delta", "epsilon"]
        let registry = ToolRegistry()  // empty — sub-agents don't need tools here
        let workspace = InMemoryWorkspace()
        let permissions = DefaultPermissionChecker(mode: .auto)
        let providerBox = ProviderFactoryBox()

        let batch = BatchExecutor(concurrency: 3) { [providerBox] in
            let provider = providerBox.next()
            return SubAgentExecutor(
                workspace: workspace,
                toolRegistry: registry,
                provider: provider,
                permissionChecker: permissions,
                config: SubAgentConfig(systemPrompt: "", model: "gpt-4o", maxTurns: 3)
            )
        }

        let results = try await batch.execute(items: items) { item in
            "analyze \(item)"
        }

        #expect(results.count == items.count)
        for (i, result) in results.enumerated() {
            #expect(result.item == items[i])
            #expect(result.index == i)
            #expect(result.output.hasPrefix("answer-"))
        }
    }

    @Test func emitsProgressEvents() async throws {
        let items = ["a", "b", "c"]
        let providerBox = ProviderFactoryBox()
        let registry = ToolRegistry()
        let workspace = InMemoryWorkspace()
        let permissions = DefaultPermissionChecker(mode: .auto)

        let batch = BatchExecutor(concurrency: 2) { [providerBox] in
            let provider = providerBox.next()
            return SubAgentExecutor(
                workspace: workspace,
                toolRegistry: registry,
                provider: provider,
                permissionChecker: permissions,
                config: SubAgentConfig(systemPrompt: "", model: "gpt-4o", maxTurns: 2)
            )
        }

        actor EventRecorder {
            var events: [AgentEvent] = []
            func record(_ e: AgentEvent) { events.append(e) }
        }
        let recorder = EventRecorder()

        _ = try await batch.execute(items: items, promptBuilder: { "do \($0)" }) { event in
            await recorder.record(event)
        }
        let events = await recorder.events
        #expect(events.contains(where: { if case .harnessBatchStart(3) = $0 { return true } else { return false } }))
        let progressCount = events.filter {
            if case .harnessBatchProgress = $0 { return true } else { return false }
        }.count
        #expect(progressCount == 3)
    }

    @Test func handlesEmptyBatch() async throws {
        let batch = BatchExecutor(concurrency: 3) {
            SubAgentExecutor(
                workspace: InMemoryWorkspace(),
                toolRegistry: ToolRegistry(),
                provider: MockLLMProvider(script: []),
                permissionChecker: DefaultPermissionChecker(mode: .auto),
                config: SubAgentConfig(systemPrompt: "", model: "m")
            )
        }
        let results = try await batch.execute(items: [Int](), promptBuilder: { "\($0)" })
        #expect(results.isEmpty)
    }
}

/// Hands out a distinct MockLLMProvider per call so parallel sub-agents don't
/// share scripted state.
final class ProviderFactoryBox: @unchecked Sendable {
    private let lock = NSLock()
    private var counter = 0

    func next() -> MockLLMProvider {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        return MockLLMProvider(script: [.response(text: "answer-\(counter)")])
    }
}
