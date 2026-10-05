import Foundation
import FoundationModels

/// Configuration for a ``HarnessEngine`` run.
public struct HarnessContext: Sendable {
    /// Foundation Models model used by LLM phases.
    public let model: any LanguageModel

    /// The tool registry. Per-phase filtering happens internally.
    public let toolRegistry: ToolRegistry

    /// Permission checker.
    public let permissionChecker: any PermissionChecker

    /// Workspace for phase I/O.
    public let workspace: any WorkspaceProvider

    /// Ask-user handler for `llmHumanInput` phases.
    public let askUserHandler: (any AskUserHandler)?

    /// Metadata propagated into every ``PhaseContext``.
    public let metadata: [String: JSONValue]

    /// Default generation options for LLM phases that don't override.
    public let generationOptions: GenerationOptions

    public init(
        model: any LanguageModel = SystemLanguageModel.default,
        toolRegistry: ToolRegistry,
        permissionChecker: any PermissionChecker,
        workspace: any WorkspaceProvider,
        askUserHandler: (any AskUserHandler)? = nil,
        metadata: [String: JSONValue] = [:],
        generationOptions: GenerationOptions = .init()
    ) {
        self.model = model
        self.toolRegistry = toolRegistry
        self.permissionChecker = permissionChecker
        self.workspace = workspace
        self.askUserHandler = askUserHandler
        self.metadata = metadata
        self.generationOptions = generationOptions
    }
}

/// Executes a ``HarnessDefinition`` as a phase state machine.
///
/// The engine emits ``AgentEvent`` values for every lifecycle transition —
/// phase starts, completions, errors, batch progress, human input requests,
/// and the terminal ``AgentEvent/harnessComplete``. Consumers typically
/// forward these to their transport (SSE, WebSocket, log) without
/// interpretation.
public actor HarnessEngine {
    /// The harness being executed.
    public let definition: HarnessDefinition

    /// Immutable execution context.
    public let context: HarnessContext

    private var status: HarnessRunStatus = .pending
    private var currentIndex: Int = 0
    private var lastError: Error?

    public init(definition: HarnessDefinition, context: HarnessContext) {
        self.definition = definition
        self.context = context
    }

    /// Current status snapshot.
    public func currentStatus() -> HarnessRunStatus { status }

    /// Current phase index (0-based), 0 before the run starts.
    public func currentPhaseIndex() -> Int { currentIndex }

    /// Mark the engine as paused. Isolated helper callable from Sendable
    /// closures via `await`.
    private func markPaused() { status = .paused }

    /// Mark the engine as running. Isolated helper callable from Sendable
    /// closures via `await`.
    private func markRunning() { status = .running }

    /// Run the harness.
    ///
    /// The returned stream yields ``AgentEvent`` values as phases progress.
    /// The stream finishes cleanly when all phases (including any gatekeeper
    /// and post-harness) complete, or throws when a phase errors and is not
    /// caught.
    public nonisolated func run() -> AsyncThrowingStream<AgentEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.execute(continuation: continuation)
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    private func execute(continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation) async {
        status = .running
        let ordered = definition.allPhasesInOrder
        let total = ordered.count

        for (index, phase) in ordered.enumerated() {
            currentIndex = index
            if Task.isCancelled {
                status = .cancelled
                continuation.finish()
                return
            }

            continuation.yield(.harnessPhaseStart(
                name: phase.name,
                index: index,
                total: total
            ))

            do {
                let summary = try await runPhaseWithRetry(phase, index: index, total: total, continuation: continuation)
                continuation.yield(.harnessPhaseComplete(name: phase.name, summary: summary))
            } catch is CancellationError {
                status = .cancelled
                continuation.finish()
                return
            } catch {
                lastError = error
                status = .failed
                continuation.yield(.harnessPhaseError(
                    name: phase.name,
                    error: error.localizedDescription
                ))
                continuation.finish(throwing: error)
                return
            }
        }

        status = .completed
        continuation.yield(.harnessComplete)
        continuation.finish()
    }

    private func runPhaseWithRetry(
        _ phase: PhaseDefinition,
        index: Int,
        total: Int,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> String {
        let maxAttempts = phase.retryPolicy.maxAttempts
        var attempt = 1
        while true {
            do {
                return try await runPhase(phase, index: index, total: total, continuation: continuation)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < maxAttempts else { throw error }
                let nextAttempt = attempt + 1
                continuation.yield(.status("Phase '\(phase.name)' failed on attempt \(attempt)/\(maxAttempts): \(error.localizedDescription). Retrying attempt \(nextAttempt)."))
                if let backoff = phase.retryPolicy.backoff {
                    try await Task.sleep(for: backoff)
                }
                attempt = nextAttempt
            }
        }
    }

    private func runPhase(
        _ phase: PhaseDefinition,
        index: Int,
        total: Int,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> String {
        let phaseContext = PhaseContext(
            workspace: context.workspace,
            harnessType: definition.type,
            phaseIndex: index,
            totalPhases: total,
            metadata: context.metadata
        )

        let work: @Sendable () async throws -> String = { [self] in
            switch phase.execution {
            case .programmatic(let body):
                return try await body(phaseContext)

            case .llmSingle(let promptBuilder):
                let prompt = try await promptBuilder(phaseContext)
                return try await self.runSingleLLM(
                    phase: phase,
                    prompt: prompt
                )

            case .llmAgent(let promptBuilder, let maxTurns):
                let prompt = try await promptBuilder(phaseContext)
                return try await self.runAgentPhase(
                    phase: phase,
                    prompt: prompt,
                    maxTurns: maxTurns
                )

            case .llmBatchAgents(let concurrency, let itemsLoader, let itemPromptBuilder, let maxTurnsPerItem, let formatter):
                let items = try await itemsLoader(phaseContext)
                return try await self.runBatchPhase(
                    phase: phase,
                    concurrency: concurrency,
                    items: items,
                    itemPromptBuilder: itemPromptBuilder,
                    maxTurnsPerItem: maxTurnsPerItem,
                    formatter: formatter,
                    continuation: continuation
                )

            case .llmHumanInput(let questionBuilder):
                let question = try await questionBuilder(phaseContext)
                continuation.yield(.harnessHumanInput(question: question))
                await self.markPaused()
                guard let handler = self.context.askUserHandler else {
                    throw HarnessError.missingAskUserHandler
                }
                let response = try await handler.askUser(question: question)
                await self.markRunning()
                return response
            }
        }

        let result: String
        if let timeout = phase.timeout {
            result = try await withTimeout(timeout, phase: phase.name, work: work)
        } else {
            result = try await work()
        }

        if let outputValidation = phase.outputValidation {
            try outputValidation.validate(result, phase: phase.name)
        }

        if let output = phase.workspaceOutput {
            try await context.workspace.writeFile(
                path: output,
                content: result,
                source: .harness
            )
        }

        if let postExecute = phase.postExecute {
            try await postExecute(result, context.workspace)
        }

        return result
    }

    // MARK: Per-phase dispatch

    private func runSingleLLM(
        phase: PhaseDefinition,
        prompt: String
    ) async throws -> String {
        let curated = context.toolRegistry.filtered(allowing: phase.tools)
        let query = QueryContext(
            model: context.model,
            toolRegistry: curated,
            permissionChecker: context.permissionChecker,
            workspace: context.workspace,
            systemPrompt: phase.systemPrompt,
            maxTurns: 3,
            maximumToolCalls: 3,
            generationOptions: GenerationOptions(
                temperature: phase.temperature ?? context.generationOptions.temperature,
                maximumResponseTokens: phase.maxTokens ?? context.generationOptions.maximumResponseTokens
            )
        )
        let result = runAgent(
            context: query,
            initialMessages: [ConversationMessage(role: .user, text: prompt)]
        )
        var collected = ""
        for try await event in result.events {
            if case .turnComplete(let message, _) = event {
                collected = message.plainText
            }
        }
        return collected
    }

    private func runAgentPhase(
        phase: PhaseDefinition,
        prompt: String,
        maxTurns: Int
    ) async throws -> String {
        let curated = context.toolRegistry.filtered(allowing: phase.tools)
        let executor = SubAgentExecutor(
            workspace: context.workspace,
            toolRegistry: curated,
            model: context.model,
            permissionChecker: context.permissionChecker,
            config: SubAgentConfig(
                systemPrompt: phase.systemPrompt,
                model: context.model,
                maxTokens: phase.maxTokens ?? context.generationOptions.maximumResponseTokens ?? 4096,
                maxTurns: maxTurns
            ),
            maximumToolCalls: maxTurns
        )
        return try await executor.run(initialMessage: prompt)
    }

    private func runBatchPhase(
        phase: PhaseDefinition,
        concurrency: Int,
        items: [PhaseBatchItem],
        itemPromptBuilder: @Sendable @escaping (PhaseBatchItem) -> String,
        maxTurnsPerItem: Int,
        formatter: @Sendable @escaping ([BatchResult<PhaseBatchItem>]) -> String,
        continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
    ) async throws -> String {
        let curated = context.toolRegistry.filtered(allowing: phase.tools)
        let systemPrompt = phase.systemPrompt
        let model = context.model
        let permissionChecker = context.permissionChecker
        let workspace = context.workspace
        let maxTokens = phase.maxTokens ?? context.generationOptions.maximumResponseTokens ?? 4096

        let batch = BatchExecutor(concurrency: concurrency) {
            SubAgentExecutor(
                workspace: workspace,
                toolRegistry: curated,
                model: model,
                permissionChecker: permissionChecker,
                config: SubAgentConfig(
                    systemPrompt: systemPrompt,
                    model: model,
                    maxTokens: maxTokens,
                    maxTurns: maxTurnsPerItem
                ),
                maximumToolCalls: maxTurnsPerItem
            )
        }

        let results = try await batch.execute(
            items: items,
            promptBuilder: itemPromptBuilder
        ) { event in
            continuation.yield(event)
        }

        return formatter(results)
    }
}

/// Harness-specific errors.
public enum HarnessError: Error, Sendable, Equatable, LocalizedError {
    /// The phase called `ask_user` but no handler is configured.
    case missingAskUserHandler
    /// A phase exceeded its timeout.
    case timeout(phase: String, duration: Duration)
    /// A phase produced output that failed validation.
    case outputValidationFailed(phase: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .missingAskUserHandler:
            return "Harness phase requested human input but no AskUserHandler is configured."
        case .timeout(let phase, let duration):
            return "Harness phase '\(phase)' exceeded timeout \(duration)."
        case .outputValidationFailed(let phase, let reason):
            return "Harness phase '\(phase)' output validation failed: \(reason)."
        }
    }
}

/// Wrap a closure with a timeout. Throws ``HarnessError/timeout(phase:duration:)``
/// if the work doesn't complete in time.
func withTimeout<T: Sendable>(
    _ duration: Duration,
    phase: String = "",
    work: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask {
            try await work()
        }
        group.addTask {
            try await Task.sleep(for: duration)
            return nil
        }
        guard let winner = try await group.next() else {
            throw CancellationError()
        }
        group.cancelAll()
        if let value = winner {
            return value
        } else {
            throw HarnessError.timeout(phase: phase, duration: duration)
        }
    }
}
