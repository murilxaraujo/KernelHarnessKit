import Foundation
import KernelHarnessKit

@main
struct KBAgent {
    static func main() async throws {
        let prompt = Array(CommandLine.arguments.dropFirst()).joined(separator: " ")
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            fputs("set OPENAI_API_KEY\n", stderr)
            return
        }

        let registry = ToolRegistry()
        registry.registerBuiltIns()
        registry.register(KBSearchTool())

        let context = QueryContext(
            provider: OpenAICompatibleProvider.openai(apiKey: key),
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: InMemoryWorkspace(),
            model: "openai/gpt-4o-mini",
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
