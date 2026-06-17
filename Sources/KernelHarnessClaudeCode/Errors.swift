import Foundation

/// Errors produced by ``ClaudeCodeProvider``.
public enum ClaudeCodeProviderError: Error, CustomStringConvertible, Sendable {
    /// The `claude` binary could not be located on the target path.
    case binaryNotFound(path: String)

    /// The CLI reported that no Anthropic credentials were available. Common
    /// remediation: run `claude auth login`, or set `ANTHROPIC_API_KEY`.
    case notAuthenticated(detail: String)

    /// `claude -p` exited with a non-zero status. `stderrTail` contains the
    /// last few lines of stderr, useful for diagnosis.
    case processFailed(exitCode: Int32, stderrTail: String)

    /// The CLI produced an NDJSON event whose schema did not match the subset
    /// this provider knows how to parse. Non-fatal in practice — the provider
    /// logs and continues — but surfaces to callers when it prevents
    /// completion of a turn.
    case schemaMismatch(reason: String)

    /// The CLI emitted an explicit `result.error` event.
    case cliError(message: String)

    /// Streaming was cancelled by the caller.
    case cancelled

    /// Provider is being used on a platform that cannot spawn subprocesses.
    case unsupportedPlatform

    public var description: String {
        switch self {
        case .binaryNotFound(let path):
            return "claude binary not found at '\(path)'. Install it from https://claude.com/claude-code or pass an explicit executablePath."
        case .notAuthenticated(let detail):
            return "Claude Code is not authenticated (\(detail)). Run `claude auth login` to authenticate, or set ANTHROPIC_API_KEY for API-key auth."
        case .processFailed(let exitCode, let stderrTail):
            return "claude exited with code \(exitCode). stderr tail:\n\(stderrTail)"
        case .schemaMismatch(let reason):
            return "Claude Code emitted an unexpected stream-json event: \(reason)"
        case .cliError(let message):
            return "Claude Code reported an error: \(message)"
        case .cancelled:
            return "Claude Code streaming cancelled."
        case .unsupportedPlatform:
            return "ClaudeCodeProvider can only run on platforms that support Foundation.Process (macOS, Linux)."
        }
    }
}
