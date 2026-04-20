import Foundation

/// Coarse-grained permission mode for a session.
public enum PermissionMode: Sendable, Hashable {
    /// Default mode — read-only invocations pass without confirmation, but
    /// writes surface a confirmation prompt.
    case `default`

    /// Allow every invocation without confirmation. Use for background jobs
    /// and agents operating in isolated environments.
    case auto

    /// Block every write invocation. Read-only tools still run.
    case readOnly

    /// Use a custom policy.
    case custom(PermissionPolicy)
}

/// A custom permission policy — path rules, command deny list, per-tool
/// overrides.
public struct PermissionPolicy: Sendable, Hashable {
    public var pathRules: [PathRule]
    public var commandDenyList: [String]
    public var toolOverrides: [String: ToolOverride]

    public init(
        pathRules: [PathRule] = [],
        commandDenyList: [String] = [],
        toolOverrides: [String: ToolOverride] = [:]
    ) {
        self.pathRules = pathRules
        self.commandDenyList = commandDenyList
        self.toolOverrides = toolOverrides
    }
}

/// A per-file-path rule.
public struct PathRule: Sendable, Hashable {
    /// A glob pattern matching workspace paths (`**`, `*`, `?` supported).
    public let pattern: String

    /// What to do when a tool invocation targets a matching path.
    public let permission: PathPermission

    public init(pattern: String, permission: PathPermission) {
        self.pattern = pattern
        self.permission = permission
    }
}

public enum PathPermission: Sendable, Hashable {
    /// Allow invocations targeting matching paths.
    case allow
    /// Deny invocations targeting matching paths.
    case deny
    /// Require user confirmation.
    case askUser
}

/// Per-tool override.
public enum ToolOverride: Sendable, Hashable {
    /// Always allow invocations of this tool.
    case allow
    /// Always deny invocations of this tool.
    case deny
    /// Require user confirmation.
    case askUser
}
