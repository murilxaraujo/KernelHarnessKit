import Foundation
import FoundationModels

/// Shared context for a single query run.
///
/// Built by the consumer from a model facade, a tool registry, a workspace, and
/// tuning knobs. Passed into ``runAgent(context:initialMessages:)``.
public struct QueryContext: Sendable {
    /// Foundation Models language model used by this query.
    public let model: any LanguageModel

    /// Tools the agent can invoke.
    public let toolRegistry: ToolRegistry

    /// Permission checker gating every tool invocation.
    public let permissionChecker: any PermissionChecker

    /// Workspace for file I/O.
    public let workspace: any WorkspaceProvider

    /// System prompt.
    public let systemPrompt: String

    /// Turn budget. The loop aborts with ``AgentError/maxTurnsExceeded(_:)``
    /// if reached. The HLD default (matching OpenHarness) is 200.
    public let maxTurns: Int
    public let maximumToolCalls: Int

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
        model: any LanguageModel = SystemLanguageModel.default,
        toolRegistry: ToolRegistry,
        permissionChecker: any PermissionChecker,
        workspace: any WorkspaceProvider,
        systemPrompt: String = "",
        maxTurns: Int = 200,
        maximumToolCalls: Int? = nil,
        generationOptions: GenerationOptions = .init(),
        toolMetadata: [String: JSONValue] = [:],
        todoManager: TodoManager? = nil,
        subAgentFactory: (@Sendable () -> SubAgentExecutor)? = nil,
        askUserHandler: (any AskUserHandler)? = nil
    ) {
        self.model = model
        self.toolRegistry = toolRegistry
        self.permissionChecker = permissionChecker
        self.workspace = workspace
        self.systemPrompt = systemPrompt
        self.maxTurns = maxTurns
        self.maximumToolCalls = maximumToolCalls ?? maxTurns
        self.generationOptions = generationOptions
        self.toolMetadata = toolMetadata
        self.todoManager = todoManager
        self.subAgentFactory = subAgentFactory
        self.askUserHandler = askUserHandler
    }

    /// Generation parameters forwarded to Foundation Models.
    public let generationOptions: GenerationOptions

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
