import Foundation
import KernelHarnessKit
import FoundationModels

@main
struct KBAgent {
    static func main() async throws {
        let prompt = Array(CommandLine.arguments.dropFirst()).joined(separator: " ")
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        registry.register(KBSearchTool())

        let context = QueryContext(
            model: SystemLanguageModel.default,
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: InMemoryWorkspace(),
            systemPrompt: "You are a KB agent. Call kb_search before answering."
        )

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: prompt)]
        )

        for try await event in result.events {
            if case .textChunk(let text) = event {
                FileHandle.standardOutput.write(Data(text.utf8))
            }
        }
        print()
    }
}
