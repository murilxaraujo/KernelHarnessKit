import Foundation

/// The normalized result of running a tool.
///
/// Tools always return a `ToolResult` — even on failure. Raising an error past
/// the tool layer is reserved for unrecoverable engine-level problems; a tool
/// that received bad input, hit a timeout, or encountered an expected failure
/// should return `ToolResult(output: reason, isError: true)` so the agent loop
/// can surface the result to the model and let it adapt.
public struct ToolResult: Sendable, Hashable {
    /// The human-readable output, formatted for inclusion in the model's
    /// context window. Prefer plain text or compact JSON.
    public let output: String

    /// `true` when the tool failed. The agent loop surfaces this to the model
    /// as an error tool result, which most providers annotate for the model.
    public let isError: Bool

    /// Arbitrary structured metadata attached to the result. Not shown to the
    /// model but available to the consumer (e.g., for telemetry or UI badges).
    public let metadata: [String: JSONValue]

    public init(
        output: String,
        isError: Bool = false,
        metadata: [String: JSONValue] = [:]
    ) {
        self.output = output
        self.isError = isError
        self.metadata = metadata
    }

    /// Convenience for a successful result with plain text output.
    public static func success(_ output: String, metadata: [String: JSONValue] = [:]) -> ToolResult {
        ToolResult(output: output, isError: false, metadata: metadata)
    }

    /// Convenience for a failure result with a reason message.
    public static func failure(_ reason: String, metadata: [String: JSONValue] = [:]) -> ToolResult {
        ToolResult(output: reason, isError: true, metadata: metadata)
    }
}
