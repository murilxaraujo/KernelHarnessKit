import Foundation

/// Tool: `write_todos` — atomically replace the agent's plan.
public struct WriteTodosTool: Tool {
    public let name = "write_todos"
    public let description = """
    Replace the agent's full todo list. Use this to plan multi-step work, \
    keep track of progress, and communicate intent to the user. Pass the \
    entire updated list every time — it replaces the current state.
    """

    public struct Input: Codable, Sendable {
        public let todos: [TodoItem]
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "todos": .array(
                items: .object(
                    properties: [
                        "content": .string(description: "What the item says"),
                        "status": .string(
                            description: "One of pending, in_progress, completed",
                            enum: ["pending", "in_progress", "completed"]
                        ),
                    ],
                    required: ["content", "status"]
                )
            )
        ],
        required: ["todos"]
    )

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        guard let manager = context.todoManager else {
            return .failure("no todo manager configured for this session")
        }
        try await manager.replace(input.todos)
        return .success("replaced todos (\(input.todos.count) items)")
    }
}

/// Tool: `read_todos` — read the current plan.
public struct ReadTodosTool: Tool {
    public let name = "read_todos"
    public let description = "Read the current todo list."

    public struct Input: Codable, Sendable {}

    public static let inputSchema = JSONSchema.object(properties: [:])

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        guard let manager = context.todoManager else {
            return .failure("no todo manager configured for this session")
        }
        let items = await manager.current()
        if items.isEmpty {
            return .success("(no todos)")
        }
        let rows = items.enumerated().map { idx, item in
            "\(idx + 1). [\(item.status.rawValue)] \(item.content)"
        }
        return .success(rows.joined(separator: "\n"))
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}
