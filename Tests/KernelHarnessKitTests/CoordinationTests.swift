import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("BatchExecutor")
struct BatchExecutorTests {
    @Test func processesItemsInParallelAndPreservesOrder() async throws {
        let actor = CounterActor()
        let executor = BatchExecutor(concurrency: 3) {
            TestSubAgent { await actor.next() }
        }
        let results = try await executor.execute(items: ["alpha", "beta"]) { $0 }
        #expect(results.map { $0.item } == ["alpha", "beta"])
        #expect(results.map { $0.index } == [0, 1])
        #expect(results.allSatisfy { !$0.isError })
    }

    @Test func emitsProgressEvents() async throws {
        let executor = BatchExecutor(concurrency: 2) {
            TestSubAgent { "ok" }
        }
        actor EventRecorder {
            var events: [AgentEvent] = []
            func record(_ event: AgentEvent) { events.append(event) }
        }
        let recorder = EventRecorder()
        _ = try await executor.execute(items: ["a", "b"], promptBuilder: { $0 }) { event in
            await recorder.record(event)
        }
        let events = await recorder.events
        #expect(events.contains { if case .harnessBatchStart(2) = $0 { true } else { false } })
        #expect(events.filter { if case .harnessBatchProgress = $0 { true } else { false } }.count == 2)
    }

    @Test func handlesEmptyBatchWithoutRunningAgents() async throws {
        let executor = BatchExecutor(concurrency: 2) {
            Issue.record("No sub-agent should be created for an empty batch")
            return TestSubAgent { "unused" }
        }
        let results = try await executor.execute(items: [Int](), promptBuilder: { "\($0)" })
        #expect(results.isEmpty)
    }
}

private actor CounterActor {
    private var value = 0
    func next() -> String {
        value += 1
        return "answer-\(value)"
    }
}

private struct TestSubAgent: SubAgentRunning {
    let output: @Sendable () async -> String

    func run(
        initialMessage: String,
        eventHandler: (@Sendable (AgentEvent) async -> Void)? = nil
    ) async throws -> String {
        await output()
    }
}
