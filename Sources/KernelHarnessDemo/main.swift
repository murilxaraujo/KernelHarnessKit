import Foundation
import KernelHarnessKit

@main
struct KernelHarnessDemo {
    static func main() async {
        let args = CommandLine.arguments.dropFirst()
        let mode = args.first.map { String($0) } ?? "chat"
        let prompt = Array(args.dropFirst()).joined(separator: " ")

        do {
            switch mode {
            case "chat":
                try await runChat(prompt: prompt.isEmpty ? defaultChatPrompt : prompt)
            case "harness":
                try await runHarness()
            case "--help", "-h", "help":
                print(helpText)
            default:
                print(helpText)
                exit(1)
            }
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static let defaultChatPrompt = "Write a haiku about deterministic agents."

    private static let helpText = """
    kernel-harness-demo — minimal KernelHarnessKit demo

    Usage:
        kernel-harness-demo chat [prompt...]
        kernel-harness-demo harness

    Environment:
        OPENAI_API_KEY     Required for live provider calls.
        OPENAI_BASE_URL    Override the OpenAI-compatible endpoint (optional).
        KHK_DEMO_MODEL     Model id (default: openai/gpt-4o-mini).

    Modes:
        chat     Single-turn chat. Streams assistant text to stdout.
        harness  Run a 3-phase demo harness: programmatic → llmSingle → llmBatchAgents.
    """

    private static func model() -> String {
        ProcessInfo.processInfo.environment["KHK_DEMO_MODEL"] ?? "openai/gpt-4o-mini"
    }

    private static func provider() throws -> any LLMProvider {
        guard let key = ProcessInfo.processInfo.environment["OPENAI_API_KEY"] else {
            throw DemoError.missingAPIKey
        }
        let baseURL = ProcessInfo.processInfo.environment["OPENAI_BASE_URL"]
            .flatMap(URL.init(string:))
            ?? URL(string: "https://api.openai.com/v1")!
        return OpenAICompatibleProvider(apiKey: key, baseURL: baseURL)
    }

    // MARK: Chat mode

    private static func runChat(prompt: String) async throws {
        let provider = try provider()
        let registry = ToolRegistry()
        registry.registerBuiltIns()

        let workspace = InMemoryWorkspace()
        let context = QueryContext(
            provider: provider,
            toolRegistry: ToolRegistry(),
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: workspace,
            model: model(),
            systemPrompt: "You are a concise assistant. Keep answers under 60 words.",
            maxTokens: 400
        )

        print("[chat] prompt: \(prompt)")
        print("[chat] streaming response:\n")

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: prompt)]
        )
        for try await event in result.events {
            switch event {
            case .textChunk(let text):
                FileHandle.standardOutput.write(Data(text.utf8))
            case .turnComplete(_, let usage):
                if let usage {
                    print("\n\n[usage] prompt=\(usage.promptTokens) completion=\(usage.completionTokens)")
                } else {
                    print()
                }
            case .error(let message):
                print("\n[error] \(message)")
            default:
                break
            }
        }
        _ = registry
    }

    // MARK: Harness mode

    private static func runHarness() async throws {
        let provider = try provider()
        let workspace = InMemoryWorkspace()
        let registry = ToolRegistry()
        registry.registerBuiltIns()

        let definition = demoHarness()
        let context = HarnessContext(
            provider: provider,
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: workspace,
            model: model()
        )
        let engine = HarnessEngine(definition: definition, context: context)

        print("[harness] '\(definition.displayName)' starting\n")
        for try await event in engine.run() {
            switch event {
            case .harnessPhaseStart(let name, let index, let total):
                print("── phase \(index + 1)/\(total): \(name) ──")
            case .harnessPhaseComplete(let name, _):
                print("✓ \(name) complete\n")
            case .harnessPhaseError(let name, let error):
                print("✗ \(name) error: \(error)")
            case .harnessBatchStart(let count):
                print("   batch: \(count) items")
            case .harnessBatchProgress(let current, let total):
                print("   \(current)/\(total)")
            case .harnessComplete:
                print("[harness] complete")
            default:
                break
            }
        }

        print("\nFiles in workspace:")
        for file in try await workspace.listFiles() {
            print("  \(file.path)  (\(file.sizeBytes)B, \(file.source.rawValue))")
        }
    }

    private static func demoHarness() -> HarnessDefinition {
        let prepare = PhaseDefinition(
            name: "collect",
            description: "Collect the topics to analyze.",
            systemPrompt: "",
            workspaceOutput: "topics.txt",
            execution: .programmatic { _ in
                "structured concurrency\nstrict concurrency checking\ndistributed actors"
            }
        )

        let analyze = PhaseDefinition(
            name: "analyze",
            description: "Analyze each topic in parallel with a mini agent.",
            systemPrompt: "You are an expert Swift writer. Produce one short bullet per topic — 1 line.",
            workspaceOutput: "analysis.md",
            execution: .llmBatchAgents(
                concurrency: 3,
                itemsLoader: { context in
                    let topics = try await context.workspace.readFile(path: "topics.txt")
                    return topics.split(separator: "\n").enumerated().map { idx, topic in
                        PhaseBatchItem(id: String(idx), content: String(topic))
                    }
                },
                itemPromptBuilder: { item in "Summarize the topic: \(item.content)" },
                maxTurnsPerItem: 2,
                resultFormatter: { results in
                    results.map { "- \($0.output)" }.joined(separator: "\n")
                }
            )
        )

        let summarize = PhaseDefinition(
            name: "summarize",
            description: "Produce a single-paragraph summary from the analysis.",
            systemPrompt: "You are a concise editor. Turn the bullets into a single paragraph under 80 words.",
            workspaceOutput: "summary.md",
            execution: .llmSingle(
                promptBuilder: { context in
                    let analysis = try await context.workspace.readFile(path: "analysis.md")
                    return "Summarize these bullets:\n\n\(analysis)"
                },
                responseFormat: nil
            )
        )

        return HarnessDefinition(
            type: "swift_concurrency_demo",
            displayName: "Swift Concurrency Demo",
            description: "Gather → analyze → summarize, end-to-end in three phases.",
            phases: [prepare, analyze, summarize]
        )
    }
}

enum DemoError: Error, LocalizedError {
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "OPENAI_API_KEY is not set. Export it before running this demo."
        }
    }
}
