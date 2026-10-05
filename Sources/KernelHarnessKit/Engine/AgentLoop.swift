import Foundation
import FoundationModels

/// Result of a model-backed agent run.
public struct AgentRunResult: Sendable {
    public let events: AsyncThrowingStream<AgentEvent, Error>
    public let finalMessages: @Sendable () async -> [ConversationMessage]
}

/// Run a Foundation Models session, forwarding native response streaming and
/// tool lifecycle into KernelHarnessKit's transport-neutral event stream.
public func runAgent(
    context: QueryContext,
    initialMessages: [ConversationMessage]
) -> AgentRunResult {
    let buffer = MessageBuffer(messages: initialMessages)
    let stream = AsyncThrowingStream<AgentEvent, Error> { continuation in
        let executionContext = ToolExecutionContext(
            workspace: context.workspace,
            permissionChecker: context.permissionChecker,
            metadata: context.toolMetadata,
            todoManager: context.todoManager,
            subAgentFactory: context.subAgentFactory,
            askUserHandler: context.askUserHandler
        )
        let tools = context.toolRegistry.foundationTools(
            context: executionContext,
            maximumCalls: context.maximumToolCalls
        ) { event in
            continuation.yield(event)
        }
        let session = LanguageModelSession(
            model: context.model,
            tools: tools,
            instructions: context.systemPrompt
        )
        let latestUserIndex = initialMessages.lastIndex(where: { $0.role == .user })
        let transcriptHistory = latestUserIndex.map { Array(initialMessages[..<$0]) } ?? initialMessages
        var transcript = session.transcript
        transcript.append(contentsOf: makeTranscript(from: transcriptHistory))
        session.transcript = transcript
        let task = Task {
            do {
                guard let prompt = initialMessages.last(where: { $0.role == .user })?.plainText else {
                    continuation.finish()
                    return
                }
                let responseStream = session.streamResponse(
                    to: prompt,
                    options: context.generationOptions
                )
                var previous = ""
                var latest = ""
                var latestUsage = UsageSnapshot()
                for try await snapshot in responseStream {
                    latest = snapshot.content
                    if latest.hasPrefix(previous) {
                        let delta = String(latest.dropFirst(previous.count))
                        if !delta.isEmpty { continuation.yield(.textChunk(delta)) }
                    } else if !latest.isEmpty {
                        continuation.yield(.textChunk(latest))
                    }
                    previous = latest
                    latestUsage = UsageSnapshot(
                        promptTokens: snapshot.usage.input.totalTokenCount,
                        completionTokens: snapshot.usage.output.totalTokenCount
                    )
                }
                let assistant = ConversationMessage(role: .assistant, text: latest)
                await buffer.append(assistant)
                continuation.yield(.turnComplete(assistant, latestUsage))
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

private func makeTranscript(
    from messages: [ConversationMessage]
) -> Transcript {
    var entries: [Transcript.Entry] = []
    for message in messages where message.role == .user || message.role == .assistant {
        let segments: [Transcript.Segment] = [.text(.init(content: message.plainText))]
        if message.role == .user {
            entries.append(.prompt(Transcript.Prompt(segments: segments)))
        } else {
            entries.append(.response(Transcript.Response(segments: segments)))
        }
    }
    return Transcript(entries: entries)
}

actor MessageBuffer {
    private(set) var messages: [ConversationMessage]

    init(messages: [ConversationMessage]) { self.messages = messages }
    func append(_ message: ConversationMessage) { messages.append(message) }
    func snapshot() -> [ConversationMessage] { messages }
}
