import Foundation

/// Tool: `task` — delegate to a sub-agent with an isolated conversation.
public struct TaskTool: Tool {
    public let name = "task"
    public let description = """
    Delegate a focused task to a sub-agent. The sub-agent starts fresh — \
    it does not see this conversation — but shares the workspace, so pass \
    inputs via files. Use for exploration, tangent work, or research that \
    would pollute this conversation's context. The return value is the \
    sub-agent's final answer.
    """

    public struct Input: Codable, Sendable {
        public let description: String
        public let prompt: String
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "description": .string(description: "Short 3-5 word description of the task"),
            "prompt": .string(description: "The full prompt for the sub-agent"),
        ],
        required: ["description", "prompt"]
    )

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        guard let factory = context.subAgentFactory else {
            return .failure("no sub-agent factory configured for this session")
        }
        let executor = factory()
        do {
            let output = try await executor.run(initialMessage: input.prompt)
            return .success(output)
        } catch {
            return .failure("sub-agent failed: \(error.localizedDescription)")
        }
    }
}

/// Tool: `ask_user` — pause the run until the user responds.
public struct AskUserTool: Tool {
    public let name = "ask_user"
    public let description = """
    Ask the user a clarifying question and wait for their answer. Use \
    sparingly — prefer making reasonable assumptions and proceeding. Best \
    when you need a piece of information you cannot look up and cannot \
    safely guess.
    """

    public struct Input: Codable, Sendable {
        public let question: String
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "question": .string(description: "The question to ask the user"),
        ],
        required: ["question"]
    )

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        guard let handler = context.askUserHandler else {
            return .failure("no ask-user handler configured for this session")
        }
        do {
            let answer = try await handler.askUser(question: input.question)
            return .success(answer)
        } catch {
            return .failure("ask-user failed: \(error.localizedDescription)")
        }
    }
}
