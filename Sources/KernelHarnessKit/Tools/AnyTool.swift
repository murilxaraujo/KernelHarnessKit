import Foundation

/// A type-erased ``Tool``.
///
/// Tools are stored heterogeneously in the ``ToolRegistry`` by wrapping each
/// `Tool` in an `AnyTool`, which hides the associated `Input` type behind
/// closures that operate on `[String: JSONValue]`.
public struct AnyTool: Sendable {
    /// The underlying tool's name.
    public let name: String

    /// The underlying tool's description.
    public let description: String

    /// The underlying tool's input schema.
    public let inputSchema: JSONSchema

    private let _execute: @Sendable ([String: JSONValue], ToolExecutionContext) async -> ToolResult
    private let _isReadOnly: @Sendable ([String: JSONValue]) -> Bool

    /// Erase a concrete ``Tool`` into an ``AnyTool``.
    public init<T: Tool>(_ tool: T) {
        self.name = tool.name
        self.description = tool.description
        self.inputSchema = T.inputSchema
        self._execute = { rawInput, context in
            do {
                let input = try Self.decodeInput(rawInput, as: T.Input.self)
                return try await tool.execute(input, context: context)
            } catch let DecodingError.keyNotFound(key, _) {
                return .failure("missing required field: \(key.stringValue)")
            } catch let DecodingError.typeMismatch(_, ctx) {
                return .failure("type mismatch at \(ctx.codingPath.map(\.stringValue).joined(separator: ".")): \(ctx.debugDescription)")
            } catch let DecodingError.valueNotFound(_, ctx) {
                return .failure("missing value at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))")
            } catch let DecodingError.dataCorrupted(ctx) {
                return .failure("invalid input: \(ctx.debugDescription)")
            } catch {
                return .failure("tool execution error: \(error.localizedDescription)")
            }
        }
        self._isReadOnly = { rawInput in
            guard let input = try? Self.decodeInput(rawInput, as: T.Input.self) else {
                return false
            }
            return tool.isReadOnly(input)
        }
    }

    /// Manual construction path for tools assembled at runtime (e.g., MCP
    /// proxy tools whose `Input` type is not known at compile time).
    public init(
        name: String,
        description: String,
        inputSchema: JSONSchema,
        execute: @escaping @Sendable ([String: JSONValue], ToolExecutionContext) async -> ToolResult,
        isReadOnly: @escaping @Sendable ([String: JSONValue]) -> Bool = { _ in false }
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self._execute = execute
        self._isReadOnly = isReadOnly
    }

    /// Execute with raw JSON input.
    public func execute(rawInput: [String: JSONValue], context: ToolExecutionContext) async -> ToolResult {
        await _execute(rawInput, context)
    }

    /// Read-only check with raw JSON input.
    public func isReadOnly(rawInput: [String: JSONValue]) -> Bool {
        _isReadOnly(rawInput)
    }

    /// The tool advertised to the provider in the form OpenAI expects:
    ///
    /// ```json
    /// { "type": "function",
    ///   "function": {
    ///     "name": "...",
    ///     "description": "...",
    ///     "parameters": { ...JSON Schema... }
    ///   }
    /// }
    /// ```
    public var apiSchema: [String: Any] {
        [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": inputSchema.dictionary,
            ],
        ]
    }

    private static func decodeInput<I: Decodable>(
        _ raw: [String: JSONValue],
        as type: I.Type
    ) throws -> I {
        let data = try JSONEncoder().encode(raw)
        return try JSONDecoder().decode(I.self, from: data)
    }
}
