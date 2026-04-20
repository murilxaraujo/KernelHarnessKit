import Foundation

/// A configurable ``PermissionChecker`` that implements the ``PermissionMode``
/// semantics described in the HLD.
public struct DefaultPermissionChecker: PermissionChecker, Sendable {
    /// The active mode.
    public let mode: PermissionMode

    public init(mode: PermissionMode = .default) {
        self.mode = mode
    }

    public func evaluate(
        toolName: String,
        isReadOnly: Bool,
        filePath: String?,
        command: String?
    ) -> PermissionDecision {
        switch mode {
        case .auto:
            return .allow
        case .readOnly:
            return isReadOnly
                ? .allow
                : .deny("permission mode is readOnly — \(toolName) performs writes")
        case .default:
            return isReadOnly
                ? .allow
                : .confirm("\(toolName) performs writes")
        case .custom(let policy):
            return evaluateCustom(
                policy: policy,
                toolName: toolName,
                isReadOnly: isReadOnly,
                filePath: filePath,
                command: command
            )
        }
    }

    private func evaluateCustom(
        policy: PermissionPolicy,
        toolName: String,
        isReadOnly: Bool,
        filePath: String?,
        command: String?
    ) -> PermissionDecision {
        if let override = policy.toolOverrides[toolName] {
            switch override {
            case .allow: return .allow
            case .deny: return .deny("tool \(toolName) disabled by policy")
            case .askUser: return .confirm("tool \(toolName) requires confirmation by policy")
            }
        }

        if let command {
            for blocked in policy.commandDenyList where command.contains(blocked) {
                return .deny("command contains blocked token '\(blocked)'")
            }
        }

        if let filePath {
            for rule in policy.pathRules where GlobMatcher.matches(path: filePath, pattern: rule.pattern) {
                switch rule.permission {
                case .allow: return .allow
                case .deny: return .deny("path \(filePath) blocked by rule \(rule.pattern)")
                case .askUser: return .confirm("path \(filePath) requires confirmation")
                }
            }
        }

        return isReadOnly ? .allow : .confirm("\(toolName) performs writes")
    }
}

/// Lightweight glob matcher.
///
/// Semantics:
/// - `?` matches exactly one character, except `/`.
/// - `*` matches zero or more characters within a single path segment (does
///   not cross `/`).
/// - `**` matches zero or more characters including `/` — used to span
///   directory boundaries.
/// - Any other character matches itself.
enum GlobMatcher {
    static func matches(path: String, pattern: String) -> Bool {
        let p = Array(path)
        let g = Array(pattern)
        return match(p, 0, g, 0)
    }

    private static func match(
        _ path: [Character], _ pi: Int,
        _ pattern: [Character], _ gi: Int
    ) -> Bool {
        var pi = pi
        var gi = gi
        while gi < pattern.count {
            let ch = pattern[gi]
            // "**" — greedy across slashes
            if ch == "*", gi + 1 < pattern.count, pattern[gi + 1] == "*" {
                // Skip any additional consecutive stars.
                var nextG = gi + 2
                while nextG < pattern.count, pattern[nextG] == "*" { nextG += 1 }
                // Try to match the remainder starting at each position.
                for k in pi...path.count {
                    if match(path, k, pattern, nextG) { return true }
                }
                return false
            }
            if ch == "*" {
                // Match within segment (no slash).
                let nextG = gi + 1
                var k = pi
                while true {
                    if match(path, k, pattern, nextG) { return true }
                    if k >= path.count { return false }
                    if path[k] == "/" { return false }
                    k += 1
                }
            }
            if pi >= path.count { return false }
            if ch == "?" {
                if path[pi] == "/" { return false }
                pi += 1; gi += 1
                continue
            }
            if path[pi] != ch { return false }
            pi += 1; gi += 1
        }
        return pi == path.count
    }
}
