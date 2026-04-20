import Foundation

/// A single permission evaluation result.
public struct PermissionDecision: Sendable, Hashable {
    /// `true` if the tool invocation may proceed.
    public let allowed: Bool

    /// `true` if the invocation should trigger a user confirmation prompt.
    /// Has no effect when ``allowed`` is `false`.
    public let requiresConfirmation: Bool

    /// Human-readable reason. Surfaced to the user and optionally to the model.
    public let reason: String?

    public init(allowed: Bool, requiresConfirmation: Bool = false, reason: String? = nil) {
        self.allowed = allowed
        self.requiresConfirmation = requiresConfirmation
        self.reason = reason
    }

    /// Allow unconditionally.
    public static let allow = PermissionDecision(allowed: true)

    /// Deny unconditionally. Supply a reason where possible.
    public static func deny(_ reason: String? = nil) -> PermissionDecision {
        PermissionDecision(allowed: false, reason: reason)
    }

    /// Allow but require confirmation from the user.
    public static func confirm(_ reason: String? = nil) -> PermissionDecision {
        PermissionDecision(allowed: true, requiresConfirmation: true, reason: reason)
    }
}

/// Evaluates whether a tool invocation is permitted.
public protocol PermissionChecker: Sendable {
    /// Produce a decision for a tool invocation.
    ///
    /// - Parameters:
    ///   - toolName: The tool being invoked.
    ///   - isReadOnly: Whether the tool reports this invocation as read-only.
    ///   - filePath: The target file path, if the tool operates on a file.
    ///   - command: The target command, if the tool executes a shell command.
    func evaluate(
        toolName: String,
        isReadOnly: Bool,
        filePath: String?,
        command: String?
    ) -> PermissionDecision
}
