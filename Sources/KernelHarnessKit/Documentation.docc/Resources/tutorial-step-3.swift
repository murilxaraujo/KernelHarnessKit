import KernelHarnessKit

struct KBSearchTool: Tool {
    let name = "kb_search"
    let description = "Search the local knowledge base for relevant passages."

    struct Input: Codable, Sendable {
        let query: String
    }

    static let inputSchema = JSONSchema.object(
        properties: [
            "query": .string(description: "The user's question, rephrased for search"),
        ],
        required: ["query"]
    )

    func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        // Your real retrieval logic goes here.
        let hits = ["fact-1 about \(input.query)", "fact-2 about \(input.query)"]
        return .success(hits.joined(separator: "\n"))
    }

    func isReadOnly(_ input: Input) -> Bool { true }
}
