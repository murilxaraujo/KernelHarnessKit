import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("Agent loop")
struct AgentLoopTests {
    private func makeContext(
        provider: any LLMProvider,
        tools: ToolRegistry = makeBuiltInRegistry(),
        workspace: any WorkspaceProvider = InMemoryWorkspace(),
        maxTurns: Int = 10
    ) -> QueryContext {
        QueryContext(
            provider: provider,
            toolRegistry: tools,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            workspace: workspace,
            model: "openai/gpt-4o",
            systemPrompt: "You are a test assistant.",
            maxTurns: maxTurns
        )
    }

    private static func makeBuiltInRegistry() -> ToolRegistry {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        return registry
    }

    @Test func runsSingleTurnWithoutTools() async throws {
        let provider = MockLLMProvider(script: [
            .response(text: "hi there"),
        ])
        let context = makeContext(provider: provider)
        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "hello")]
        )

        var text = ""
        var turns = 0
        for try await event in result.events {
            switch event {
            case .textChunk(let t): text.append(t)
            case .turnComplete: turns += 1
            default: break
            }
        }
        #expect(text == "hi there")
        #expect(turns == 1)

        let final = await result.finalMessages()
        #expect(final.count == 2)
        #expect(final.last?.plainText == "hi there")
    }

    @Test func dispatchesSingleToolCall() async throws {
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "write_file", input: ["path": "a.md", "content": "hello"])
            ]),
            .response(text: "done"),
        ])
        let workspace = InMemoryWorkspace()
        let context = makeContext(provider: provider, workspace: workspace)

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "write a note")]
        )

        var toolStarts = 0
        var toolCompletes = 0
        for try await event in result.events {
            switch event {
            case .toolExecutionStarted: toolStarts += 1
            case .toolExecutionCompleted: toolCompletes += 1
            default: break
            }
        }
        #expect(toolStarts == 1)
        #expect(toolCompletes == 1)
        #expect(try await workspace.readFile(path: "a.md") == "hello")

        let final = await result.finalMessages()
        #expect(final.last?.plainText == "done")
    }

    @Test func dispatchesParallelToolCalls() async throws {
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "write_file", input: ["path": "a.md", "content": "one"]),
                .init(id: "t2", name: "write_file", input: ["path": "b.md", "content": "two"]),
            ]),
            .response(text: "done"),
        ])
        let workspace = InMemoryWorkspace()
        let context = makeContext(provider: provider, workspace: workspace)

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "write two notes")]
        )
        for try await _ in result.events {}

        #expect(try await workspace.readFile(path: "a.md") == "one")
        #expect(try await workspace.readFile(path: "b.md") == "two")
    }

    @Test func unknownToolSurfacesAsErrorResult() async throws {
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "nope", input: [:])
            ]),
            .response(text: "oops"),
        ])
        let context = makeContext(provider: provider)

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "try something bad")]
        )
        var errored = false
        for try await event in result.events {
            if case .toolExecutionCompleted(_, let r) = event, r.isError, r.output.contains("unknown tool") {
                errored = true
            }
        }
        #expect(errored)
    }

    @Test func respectsMaxTurns() async throws {
        // Script that keeps trying to call tools forever.
        let loopingResponse = MockLLMProvider.Response.response(
            toolCalls: [.init(id: "t1", name: "read_file", input: ["path": "nope"])]
        )
        let provider = MockLLMProvider(script: Array(repeating: loopingResponse, count: 100))
        let context = makeContext(provider: provider, maxTurns: 3)

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "loop")]
        )

        var didThrow = false
        do {
            for try await _ in result.events {}
        } catch {
            didThrow = true
        }
        #expect(didThrow)
        let final = await result.finalMessages()
        // 1 (initial user) + turns (assistant + tool result) * maxTurns = 1 + 2*3 = 7
        #expect(final.count >= 6)
    }

    @Test func deniedPermissionReturnsErrorResult() async throws {
        let provider = MockLLMProvider(script: [
            .response(toolCalls: [
                .init(id: "t1", name: "write_file", input: ["path": "x.md", "content": "blocked"])
            ]),
            .response(text: "ok"),
        ])
        let registry = ToolRegistry()
        registry.registerBuiltIns()

        let context = QueryContext(
            provider: provider,
            toolRegistry: registry,
            permissionChecker: DefaultPermissionChecker(mode: .readOnly),
            workspace: InMemoryWorkspace(),
            model: "gpt-4o",
            systemPrompt: "test",
            maxTurns: 5
        )

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "write file")]
        )
        var sawDeny = false
        for try await event in result.events {
            if case .toolExecutionCompleted(_, let r) = event, r.isError, r.output.contains("permission denied") {
                sawDeny = true
            }
        }
        #expect(sawDeny)
    }

    @Test func providerReceivesStrippedModelId() async throws {
        let provider = MockLLMProvider(script: [.response(text: "ok")])
        let context = makeContext(provider: provider)

        let result = runAgent(
            context: context,
            initialMessages: [ConversationMessage(role: .user, text: "ping")]
        )
        for try await _ in result.events {}
        #expect(provider.requests.first?.model == "gpt-4o")
    }
}
