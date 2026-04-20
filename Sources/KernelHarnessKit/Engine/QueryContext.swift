import Foundation

/// Shared context for a single query run.
///
/// Built by the consumer from a provider, a tool registry, a workspace, and
/// tuning knobs. Passed into ``runAgent(context:initialMessages:)``.
public struct QueryContext: Sendable {
    /// The LLM provider.
    public let provider: any LLMProvider

    /// Tools the agent can invoke.
    public let toolRegistry: ToolRegistry

    /// Permission checker gating every tool invocation.
    public let permissionChecker: any PermissionChecker

    /// Workspace for file I/O.
    public let workspace: any WorkspaceProvider

    /// Model identifier. May include a provider prefix when paired with a
    /// ``ProviderRegistry`` (e.g., `"openai/gpt-4o"`).
    public let model: String

    /// System prompt.
    public let systemPrompt: String

    /// Maximum tokens in a single LLM response.
    public let maxTokens: Int

    /// Turn budget. The loop aborts with ``AgentError/maxTurnsExceeded(_:)``
    /// if reached. The HLD default (matching OpenHarness) is 200.
    public let maxTurns: Int

    /// Sampling temperature. `nil` uses the provider's default.
    public let temperature: Double?

    /// Response format requested from the provider.
    public let responseFormat: ResponseFormat?

    /// Cross-turn metadata propagated into every ``ToolExecutionContext``.
    public let toolMetadata: [String: JSONValue]

    /// Todo manager for this run. Wired into every ``ToolExecutionContext``.
    public let todoManager: TodoManager?

    /// Factory that produces a ``SubAgentExecutor`` on demand.
    ///
    /// Supplied so the built-in `task` tool can spawn a curated sub-agent
    /// without the consumer having to wire one up per turn.
    public let subAgentFactory: (@Sendable () -> SubAgentExecutor)?

    /// Ask-user handler for human-in-the-loop flow.
    public let askUserHandler: (any AskUserHandler)?

    public init(
        provider: any LLMProvider,
        toolRegistry: ToolRegistry,
        permissionChecker: any PermissionChecker,
        workspace: any WorkspaceProvider,
        model: String,
        systemPrompt: String,
        maxTokens: Int = 4096,
        maxTurns: Int = 200,
        temperature: Double? = nil,
        responseFormat: ResponseFormat? = nil,
        toolMetadata: [String: JSONValue] = [:],
        todoManager: TodoManager? = nil,
        subAgentFactory: (@Sendable () -> SubAgentExecutor)? = nil,
        askUserHandler: (any AskUserHandler)? = nil
    ) {
        self.provider = provider
        self.toolRegistry = toolRegistry
        self.permissionChecker = permissionChecker
        self.workspace = workspace
        self.model = model
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
        self.maxTurns = maxTurns
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.toolMetadata = toolMetadata
        self.todoManager = todoManager
        self.subAgentFactory = subAgentFactory
        self.askUserHandler = askUserHandler
    }

    /// Build a ``ToolExecutionContext`` for this query.
    public func makeToolContext() -> ToolExecutionContext {
        ToolExecutionContext(
            workspace: workspace,
            permissionChecker: permissionChecker,
            metadata: toolMetadata,
            todoManager: todoManager,
            subAgentFactory: subAgentFactory,
            askUserHandler: askUserHandler
        )
    }
}
