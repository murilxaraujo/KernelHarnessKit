import Foundation

/// The result of ``runAgent(context:initialMessages:)`` — an event stream
/// plus a snapshot closure that returns the final message history once the
/// stream has finished.
///
/// Typical usage:
///
/// ```swift
/// let result = runAgent(context: context, initialMessages: [
///     ConversationMessage(role: .user, text: "hello")
/// ])
/// for try await event in result.events {
///     // surface event to the transport
/// }
/// let updated = await result.finalMessages()
/// ```
public struct AgentRunResult: Sendable {
    /// Every event emitted by the loop — text deltas, tool lifecycle, turn
    /// completion, errors.
    public let events: AsyncThrowingStream<AgentEvent, Error>

    /// Snapshot the final conversation history.
    ///
    /// Safe to call mid-stream; returns the buffer's current contents. Most
    /// consumers invoke it after draining ``events``.
    public let finalMessages: @Sendable () async -> [ConversationMessage]
}

/// Run the agent loop.
///
/// The loop is a state machine:
///
/// 1. Ask the provider to stream a completion.
/// 2. When `.messageComplete` arrives, append the assistant message to the
///    running buffer and emit ``AgentEvent/turnComplete(_:_:)``.
/// 3. If the message contains tool calls, run them — one at a time for
///    simpler event ordering, or concurrently via `TaskGroup` when the turn
///    contains multiple calls.
/// 4. Append a single `tool`-role message carrying all results and loop.
/// 5. When the model emits no tool calls, the run is complete.
///
/// Cancelling the outer `Task` propagates into the stream; the loop exits
/// after the current turn finishes.
public func runAgent(
    context: QueryContext,
    initialMessages: [ConversationMessage]
) -> AgentRunResult {
    let buffer = MessageBuffer(messages: initialMessages)

    let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
        let task = Task {
            do {
                try await runAgentLoop(
                    context: context,
                    buffer: buffer,
                    continuation: continuation
                )
                continuation.finish()
            } catch is CancellationError {
                continuation.finish()
            } catch {
                continuation.yield(.error(error.localizedDescription))
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
    }

    return AgentRunResult(
        events: stream,
        finalMessages: { await buffer.snapshot() }
    )
}

/// Actor that holds the running message buffer so the loop and tool results
/// can mutate a shared list safely.
actor MessageBuffer {
    private(set) var messages: [ConversationMessage]

    init(messages: [ConversationMessage]) {
        self.messages = messages
    }

    func append(_ message: ConversationMessage) {
        messages.append(message)
    }

    func snapshot() -> [ConversationMessage] { messages }
}

// MARK: - Loop body

private func runAgentLoop(
    context: QueryContext,
    buffer: MessageBuffer,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
) async throws {
    var turnCount = 0
    while turnCount < context.maxTurns {
        try Task.checkCancellation()
        turnCount += 1

        let snapshot = await buffer.snapshot()
        let stream = context.provider.streamChat(
            model: strippingVendorPrefix(context.model),
            messages: snapshot,
            systemPrompt: context.systemPrompt.isEmpty ? nil : context.systemPrompt,
            tools: context.toolRegistry.count == 0 ? nil : context.toolRegistry.apiSchema(),
            responseFormat: context.responseFormat,
            temperature: context.temperature,
            maxTokens: context.maxTokens
        )

        var finalMessage: ConversationMessage?
        var usage: UsageSnapshot?

        for try await chunk in stream {
            try Task.checkCancellation()
            switch chunk {
            case .textDelta(let text):
                continuation.yield(.textChunk(text))
            case .toolCallDelta:
                // Tool call deltas are absorbed into the final message by
                // the provider; they're streamed for progress UIs.
                break
            case .messageComplete(let message, let u):
                finalMessage = message
                usage = u
            case .retry(_, let delay, let reason):
                continuation.yield(.status("retrying in \(delay)s: \(reason)"))
            }
        }

        guard let assistantMessage = finalMessage else {
            throw AgentError.noFinalMessage
        }

        await buffer.append(assistantMessage)
        continuation.yield(.turnComplete(assistantMessage, usage))

        let toolCalls = assistantMessage.toolUses
        if toolCalls.isEmpty {
            return
        }

        let toolContext = context.makeToolContext()
        let resultBlocks: [ContentBlock]
        if toolCalls.count == 1 {
            let call = toolCalls[0]
            resultBlocks = [
                await executeSingleToolCall(
                    call: call,
                    toolContext: toolContext,
                    registry: context.toolRegistry,
                    continuation: continuation
                )
            ]
        } else {
            resultBlocks = try await executeParallelToolCalls(
                calls: toolCalls,
                toolContext: toolContext,
                registry: context.toolRegistry,
                continuation: continuation
            )
        }

        await buffer.append(ConversationMessage(role: .tool, content: resultBlocks))
    }

    throw AgentError.maxTurnsExceeded(context.maxTurns)
}

private func executeSingleToolCall(
    call: (id: String, name: String, input: [String: JSONValue]),
    toolContext: ToolExecutionContext,
    registry: ToolRegistry,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
) async -> ContentBlock {
    continuation.yield(.toolExecutionStarted(name: call.name, input: call.input))
    let result = await runTool(call: call, toolContext: toolContext, registry: registry)
    continuation.yield(.toolExecutionCompleted(name: call.name, result: result))
    return .toolResult(toolUseId: call.id, content: result.output, isError: result.isError)
}

private func executeParallelToolCalls(
    calls: [(id: String, name: String, input: [String: JSONValue])],
    toolContext: ToolExecutionContext,
    registry: ToolRegistry,
    continuation: AsyncThrowingStream<AgentEvent, Error>.Continuation
) async throws -> [ContentBlock] {
    for call in calls {
        continuation.yield(.toolExecutionStarted(name: call.name, input: call.input))
    }

    var ordered = [ContentBlock?](repeating: nil, count: calls.count)
    try await withThrowingTaskGroup(of: (Int, String, ToolResult).self) { group in
        for (index, call) in calls.enumerated() {
            group.addTask {
                let result = await runTool(call: call, toolContext: toolContext, registry: registry)
                return (index, call.id, result)
            }
        }
        for try await (index, toolUseId, result) in group {
            continuation.yield(.toolExecutionCompleted(name: calls[index].name, result: result))
            ordered[index] = .toolResult(
                toolUseId: toolUseId,
                content: result.output,
                isError: result.isError
            )
        }
    }
    return ordered.compactMap { $0 }
}

private func runTool(
    call: (id: String, name: String, input: [String: JSONValue]),
    toolContext: ToolExecutionContext,
    registry: ToolRegistry
) async -> ToolResult {
    guard let tool = registry.get(call.name) else {
        return .failure("unknown tool '\(call.name)'")
    }
    let filePath = call.input["path"]?.stringValue
    let command = call.input["command"]?.stringValue
    let isReadOnly = tool.isReadOnly(rawInput: call.input)
    let decision = toolContext.permissionChecker.evaluate(
        toolName: call.name,
        isReadOnly: isReadOnly,
        filePath: filePath,
        command: command
    )
    if !decision.allowed {
        return .failure("permission denied: \(decision.reason ?? "")")
    }
    return await tool.execute(rawInput: call.input, context: toolContext)
}

/// Strip a `vendor/` prefix from a model identifier. The engine passes the
/// already-routed provider the bare model id.
private func strippingVendorPrefix(_ model: String) -> String {
    if let slash = model.firstIndex(of: "/") {
        return String(model[model.index(after: slash)...])
    }
    return model
}
