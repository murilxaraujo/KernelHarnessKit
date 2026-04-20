import Foundation

/// Shared context passed to every tool invocation.
///
/// The context exposes the session's workspace, permission checker, and any
/// cross-turn metadata the tool may need. It is reconstructed for each
/// invocation so tools never hold long-lived state themselves.
public struct ToolExecutionContext: Sendable {
    /// The workspace for file I/O.
    public let workspace: any WorkspaceProvider

    /// The permission checker gating this invocation.
    public let permissionChecker: any PermissionChecker

    /// Cross-turn metadata shared between tools (e.g., the thread id, the
    /// currently executing harness phase, user locale).
    public let metadata: [String: JSONValue]

    /// The todo manager for the current thread, if any. Exposed so the
    /// planning tools can mutate the todo list.
    public let todoManager: TodoManager?

    /// The sub-agent executor for this session, if any. Required for the
    /// built-in `task` tool.
    public let subAgentFactory: (@Sendable () -> SubAgentExecutor)?

    /// The ask-user handler bridging human-in-the-loop input. Required for
    /// the built-in `ask_user` tool.
    public let askUserHandler: (any AskUserHandler)?

    public init(
        workspace: any WorkspaceProvider,
        permissionChecker: any PermissionChecker,
        metadata: [String: JSONValue] = [:],
        todoManager: TodoManager? = nil,
        subAgentFactory: (@Sendable () -> SubAgentExecutor)? = nil,
        askUserHandler: (any AskUserHandler)? = nil
    ) {
        self.workspace = workspace
        self.permissionChecker = permissionChecker
        self.metadata = metadata
        self.todoManager = todoManager
        self.subAgentFactory = subAgentFactory
        self.askUserHandler = askUserHandler
    }
}
