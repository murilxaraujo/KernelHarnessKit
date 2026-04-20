import Foundation

/// The output of a single sub-agent in a batch run.
public struct BatchResult<Item: Sendable>: Sendable {
    /// The item that produced this result.
    public let item: Item

    /// The index in the original input array.
    public let index: Int

    /// The sub-agent's final output, or the error message if it failed.
    public let output: String

    /// `true` if the sub-agent raised an error.
    public let isError: Bool

    public init(item: Item, index: Int, output: String, isError: Bool) {
        self.item = item
        self.index = index
        self.output = output
        self.isError = isError
    }
}

/// Runs N sub-agents concurrently with a configurable concurrency limit.
///
/// Used by `.llmBatchAgents` harness phases to fan out per-item analysis
/// (e.g., analyzing clauses in a contract, running fact checks on each
/// paragraph of a draft). The executor:
///
/// - Spawns at most ``concurrency`` sub-agents at once (back-pressure).
/// - Collects results in input order.
/// - Surfaces per-item failures as ``BatchResult/isError`` — one failed
///   sub-agent does not fail the batch.
/// - Emits progress events if an emitter is supplied.
public struct BatchExecutor: Sendable {
    /// Maximum number of sub-agents to run concurrently.
    public let concurrency: Int

    /// Factory that produces a fresh ``SubAgentExecutor`` per invocation.
    /// Supplied as a factory so each sub-agent has an independent message
    /// buffer and conversation.
    public let subAgentFactory: @Sendable () -> SubAgentExecutor

    public init(
        concurrency: Int = 5,
        subAgentFactory: @escaping @Sendable () -> SubAgentExecutor
    ) {
        self.concurrency = max(1, concurrency)
        self.subAgentFactory = subAgentFactory
    }

    /// Execute the batch.
    ///
    /// - Parameters:
    ///   - items: Input items. The prompt for each is built via `promptBuilder`.
    ///   - promptBuilder: Produces the initial user message for each item.
    ///   - eventEmitter: Optional callback invoked with progress events as
    ///     items complete.
    /// - Returns: Results in the same order as `items`.
    public func execute<Item: Sendable>(
        items: [Item],
        promptBuilder: @escaping @Sendable (Item) -> String,
        eventEmitter: (@Sendable (AgentEvent) async -> Void)? = nil
    ) async throws -> [BatchResult<Item>] {
        if items.isEmpty { return [] }

        await eventEmitter?(.harnessBatchStart(itemCount: items.count))

        var results = [BatchResult<Item>?](repeating: nil, count: items.count)

        try await withThrowingTaskGroup(of: BatchResult<Item>.self) { group in
            var started = 0
            var completed = 0

            // Seed the group up to concurrency
            while started < items.count && started < concurrency {
                let index = started
                let item = items[index]
                let prompt = promptBuilder(item)
                let factory = subAgentFactory
                group.addTask {
                    await runOne(
                        index: index,
                        item: item,
                        prompt: prompt,
                        factory: factory
                    )
                }
                started += 1
            }

            // Drain + refill
            while let result = try await group.next() {
                results[result.index] = result
                completed += 1
                await eventEmitter?(.harnessBatchProgress(
                    current: completed,
                    total: items.count
                ))
                if started < items.count {
                    let index = started
                    let item = items[index]
                    let prompt = promptBuilder(item)
                    let factory = subAgentFactory
                    group.addTask {
                        await runOne(
                            index: index,
                            item: item,
                            prompt: prompt,
                            factory: factory
                        )
                    }
                    started += 1
                }
            }
        }

        return results.compactMap { $0 }
    }
}

/// Run a single sub-agent, returning a ``BatchResult`` that captures either
/// the final output or the error message.
private func runOne<Item: Sendable>(
    index: Int,
    item: Item,
    prompt: String,
    factory: @Sendable () -> SubAgentExecutor
) async -> BatchResult<Item> {
    let executor = factory()
    do {
        let output = try await executor.run(initialMessage: prompt)
        return BatchResult(item: item, index: index, output: output, isError: false)
    } catch {
        return BatchResult(
            item: item,
            index: index,
            output: error.localizedDescription,
            isError: true
        )
    }
}
