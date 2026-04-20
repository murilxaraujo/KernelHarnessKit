import Foundation

/// A capability the agent can invoke.
///
/// Every tool has a stable ``name``, a natural-language ``description`` shown
/// to the model, a `Codable` ``Input`` type that validates arguments, and an
/// ``execute(_:context:)`` method that performs the work.
///
/// ### Declaring a tool
///
/// ```swift
/// struct SearchTool: Tool {
///     let name = "search"
///     let description = "Search the knowledge base"
///     static let inputSchema = JSONSchema.object(
///         properties: ["query": .string(description: "Search query")],
///         required: ["query"]
///     )
///
///     struct Input: Codable, Sendable { let query: String }
///
///     func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
///         return .success("found nothing for '\(input.query)'")
///     }
///
///     func isReadOnly(_ input: Input) -> Bool { true }
/// }
/// ```
///
/// Register the tool into a ``ToolRegistry`` by calling `ToolRegistry.register`.
/// Tool input is decoded from the model-supplied JSON using `JSONEncoder`/
/// `JSONDecoder`; input that doesn't match the `Input` type surfaces as a
/// ``ToolResult`` with ``ToolResult/isError`` set, never as a thrown error.
public protocol Tool: Sendable {
    /// The `Codable` type that parses this tool's JSON arguments.
    associatedtype Input: Codable & Sendable

    /// Stable tool name. Must be a valid identifier acceptable to the LLM
    /// provider (OpenAI accepts `[a-zA-Z0-9_-]` up to 64 chars).
    var name: String { get }

    /// Natural-language description shown to the model.
    var description: String { get }

    /// JSON Schema for the `Input` type.
    static var inputSchema: JSONSchema { get }

    /// Execute the tool with validated input.
    func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult

    /// Whether this invocation is read-only (affects permission gating).
    ///
    /// Defaults to `false`. Override when the tool doesn't mutate external
    /// state so it can be run under restrictive permission modes.
    func isReadOnly(_ input: Input) -> Bool
}

extension Tool {
    public func isReadOnly(_ input: Input) -> Bool { false }
}
