import Foundation

/// Configuration for a sub-agent.
public struct SubAgentConfig: Sendable {
    /// System prompt for the sub-agent.
    public let systemPrompt: String

    /// Model identifier (e.g., `"openai/gpt-4o-mini"`).
    public let model: String

    /// Maximum tokens in a single LLM response.
    public let maxTokens: Int

    /// Maximum turns the sub-agent may take before giving up.
    public let maxTurns: Int

    public init(
        systemPrompt: String,
        model: String,
        maxTokens: Int = 4096,
        maxTurns: Int = 15
    ) {
        self.systemPrompt = systemPrompt
        self.model = model
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
    }
}

/// Runs a full agent loop with an isolated conversation history and curated
/// tool set, returning the last assistant text as the result.
///
/// Sub-agents share the parent session's ``WorkspaceProvider`` so they can
/// read inputs and produce outputs through files, but their conversation
/// history is fresh — the parent's turns are not visible.
public struct SubAgentExecutor: Sendable {
    public let workspace: any WorkspaceProvider
    public let toolRegistry: ToolRegistry
    public let provider: any LLMProvider
    public let permissionChecker: any PermissionChecker
    public let config: SubAgentConfig

    public init(
        workspace: any WorkspaceProvider,
        toolRegistry: ToolRegistry,
        provider: any LLMProvider,
        permissionChecker: any PermissionChecker,
        config: SubAgentConfig
    ) {
        self.workspace = workspace
        self.toolRegistry = toolRegistry
        self.provider = provider
        self.permissionChecker = permissionChecker
        self.config = config
    }

    /// Run the sub-agent with an initial user message. Returns the final
    /// assistant text. Emits events through the optional `eventHandler` if
    /// provided.
    public func run(
        initialMessage: String,
        eventHandler: (@Sendable (AgentEvent) async -> Void)? = nil
    ) async throws -> String {
        // Curate the tool set: sub-agents never delegate further or mutate
        // the parent's todo list, so strip `task` and `write_todos`.
        let curated = toolRegistry.filtered(excluding: ["task", "write_todos", "read_todos"])

        let context = QueryContext(
            provider: provider,
            toolRegistry: curated,
            permissionChecker: permissionChecker,
            workspace: workspace,
            model: config.model,
            systemPrompt: config.systemPrompt,
            maxTokens: config.maxTokens,
            maxTurns: config.maxTurns
        )

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: initialMessage)]
        )

        var lastAssistantText = ""
        for try await event in result.events {
            if case .turnComplete(let message, _) = event {
                let text = message.plainText
                if !text.isEmpty { lastAssistantText = text }
            }
            await eventHandler?(event)
        }
        return lastAssistantText
    }
}
