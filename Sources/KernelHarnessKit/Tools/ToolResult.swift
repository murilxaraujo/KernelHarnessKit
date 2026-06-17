import Foundation

/// Stable error categories for failed tool calls.
public enum ToolErrorKind: String, Codable, Sendable, Hashable, CaseIterable {
    case invalidInput = "invalid_input"
    case permissionDenied = "permission_denied"
    case notFound = "not_found"
    case executionFailed = "execution_failed"
    case unknownTool = "unknown_tool"
    case unavailable = "unavailable"
}

/// Structured error details for a failed tool call.
public struct ToolError: Codable, Sendable, Hashable {
    /// Machine-readable category.
    public let kind: ToolErrorKind

    /// Human-readable explanation.
    public let message: String

    /// Additional structured details for telemetry/UI consumers.
    public let details: [String: JSONValue]

    public init(kind: ToolErrorKind, message: String, details: [String: JSONValue] = [:]) {
        self.kind = kind
        self.message = message
        self.details = details
    }
}

/// The normalized result of running a tool.
///
/// Tools always return a `ToolResult` — even on failure. Raising an error past
/// the tool layer is reserved for unrecoverable engine-level problems; a tool
/// that received bad input, hit a timeout, or encountered an expected failure
/// should return `ToolResult(output: reason, isError: true, error: ...)` so the
/// agent loop can surface the result to the model while clients receive a
/// structured error category.
public struct ToolResult: Codable, Sendable, Hashable {
    /// The human-readable output, formatted for inclusion in the model's
    /// context window. Prefer plain text or compact JSON.
    public let output: String

    /// `true` when the tool failed. The agent loop surfaces this to the model
    /// as an error tool result, which most providers annotate for the model.
    public let isError: Bool

    /// Structured error details when ``isError`` is `true`.
    public let error: ToolError?

    /// Arbitrary structured metadata attached to the result. Not shown to the
    /// model but available to the consumer (e.g., for telemetry or UI badges).
    public let metadata: [String: JSONValue]

    public init(
        output: String,
        isError: Bool = false,
        error: ToolError? = nil,
        metadata: [String: JSONValue] = [:]
    ) {
        self.output = output
        self.isError = isError
        self.error = error
        self.metadata = metadata
    }

    /// Convenience for a successful result with plain text output.
    public static func success(_ output: String, metadata: [String: JSONValue] = [:]) -> ToolResult {
        ToolResult(output: output, isError: false, metadata: metadata)
    }

    /// Convenience for a failure result with a normalized error category.
    public static func failure(
        _ reason: String,
        kind: ToolErrorKind = .executionFailed,
        metadata: [String: JSONValue] = [:],
        details: [String: JSONValue] = [:]
    ) -> ToolResult {
        ToolResult(
            output: reason,
            isError: true,
            error: ToolError(kind: kind, message: reason, details: details),
            metadata: metadata
        )
    }
}
