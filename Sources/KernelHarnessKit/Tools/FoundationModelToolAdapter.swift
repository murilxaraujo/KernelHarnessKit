import Foundation
import FoundationModels

/// Adapts a registered harness capability to Apple's native tool-call API.
/// Apple owns argument generation and the tool loop; this boundary supplies
/// KernelHarnessKit's per-run workspace and permission policy.
struct FoundationModelToolAdapter: FoundationModels.Tool, Sendable {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let tool: AnyTool
    let context: ToolExecutionContext
    let budget: ToolCallBudget
    let maximumCalls: Int
    let emit: @Sendable (AgentEvent) -> Void

    var name: String { tool.name }
    var description: String { tool.description }
    var parameters: GenerationSchema {
        (try? tool.inputSchema.foundationGenerationSchema(name: "\(tool.name)Arguments"))
            ?? GeneratedContent.generationSchema
    }

    func call(arguments: GeneratedContent) async throws -> String {
        try await budget.consume(maximum: maximumCalls)
        let data = Data(arguments.jsonString.utf8)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        let input = decoded.objectValue ?? [:]
        let callID = UUID().uuidString
        emit(.toolExecutionStarted(callId: callID, name: name, input: input))

        let decision = context.permissionChecker.evaluate(
            toolName: name,
            isReadOnly: tool.isReadOnly(rawInput: input),
            filePath: input["path"]?.stringValue,
            command: input["command"]?.stringValue
        )
        guard decision.allowed else {
            let message = "permission denied: \(decision.reason ?? "invocation blocked by permission policy")"
            let denied = ToolResult.failure(message, kind: .permissionDenied, details: ["tool": .string(name)])
            emit(.permissionDenied(callId: callID, toolName: name, reason: message, input: input))
            emit(.toolExecutionCompleted(callId: callID, name: name, result: denied))
            return message
        }
        let result = await tool.execute(rawInput: input, context: context)
        emit(.toolExecutionCompleted(callId: callID, name: name, result: result))
        if result.isError, let error = result.error, error.kind == .permissionDenied {
            emit(.permissionDenied(callId: callID, toolName: name, reason: error.message, input: input))
        }
        return result.output
    }
}

actor ToolCallBudget {
    private var calls = 0

    func consume(maximum: Int) throws {
        guard calls < maximum else {
            throw AgentError.maxTurnsExceeded(maximum)
        }
        calls += 1
    }
}
