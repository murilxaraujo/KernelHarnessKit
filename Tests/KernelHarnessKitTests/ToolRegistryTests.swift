import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("ToolRegistry")
struct ToolRegistryTests {
    @Test func registersBuiltIns() {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        #expect(registry.contains("write_file"))
        #expect(registry.contains("read_file"))
        #expect(registry.contains("edit_file"))
        #expect(registry.contains("list_files"))
        #expect(registry.contains("write_todos"))
        #expect(registry.contains("read_todos"))
        #expect(registry.contains("task"))
        #expect(registry.contains("ask_user"))
        #expect(registry.count == 8)
    }

    @Test func filterAllowing() {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        let filtered = registry.filtered(allowing: ["read_file", "list_files"])
        #expect(filtered.count == 2)
        #expect(filtered.contains("read_file"))
        #expect(filtered.contains("write_file") == false)
    }

    @Test func filterExcluding() {
        let registry = ToolRegistry()
        registry.registerBuiltIns()
        let filtered = registry.filtered(excluding: ["task", "ask_user"])
        #expect(filtered.count == 6)
        #expect(filtered.contains("task") == false)
    }

    @Test func apiSchemaShape() {
        let registry = ToolRegistry()
        registry.register(ReadFileTool())
        let schemas = registry.apiSchema()
        #expect(schemas.count == 1)
        let fn = schemas[0]["function"] as? [String: Any]
        #expect(fn?["name"] as? String == "read_file")
        #expect(fn?["description"] as? String != nil)
        #expect(fn?["parameters"] as? [String: Any] != nil)
    }

    @Test func unknownToolReturnsNil() {
        let registry = ToolRegistry()
        #expect(registry.get("nope") == nil)
    }
}

@Suite("Built-in workspace tools")
struct WorkspaceToolsTests {
    private func makeContext(workspace: any WorkspaceProvider) -> ToolExecutionContext {
        ToolExecutionContext(
            workspace: workspace,
            permissionChecker: DefaultPermissionChecker(mode: .auto)
        )
    }

    @Test func writeThenReadRoundTrips() async throws {
        let ws = InMemoryWorkspace()
        let context = makeContext(workspace: ws)

        let writer = AnyTool(WriteFileTool())
        let write = await writer.execute(
            rawInput: ["path": "note.md", "content": "hello"],
            context: context
        )
        #expect(write.isError == false)

        let reader = AnyTool(ReadFileTool())
        let read = await reader.execute(rawInput: ["path": "note.md"], context: context)
        #expect(read.output == "hello")
        #expect(read.isError == false)
    }

    @Test func readMissingReturnsError() async throws {
        let ws = InMemoryWorkspace()
        let context = makeContext(workspace: ws)
        let reader = AnyTool(ReadFileTool())
        let result = await reader.execute(rawInput: ["path": "nope.md"], context: context)
        #expect(result.isError == true)
        #expect(result.output.contains("not found"))
    }

    @Test func editFile() async throws {
        let ws = InMemoryWorkspace(seed: ["note.md": "hello world"])
        let context = makeContext(workspace: ws)
        let editor = AnyTool(EditFileTool())
        let result = await editor.execute(
            rawInput: [
                "path": "note.md",
                "old_string": "world",
                "new_string": "there",
            ],
            context: context
        )
        #expect(result.isError == false)
        #expect(try await ws.readFile(path: "note.md") == "hello there")
    }

    @Test func listFiles() async throws {
        let ws = InMemoryWorkspace(seed: ["a.md": "one", "b.md": "two"])
        let context = makeContext(workspace: ws)
        let lister = AnyTool(ListFilesTool())
        let result = await lister.execute(rawInput: [:], context: context)
        #expect(result.isError == false)
        #expect(result.output.contains("a.md"))
        #expect(result.output.contains("b.md"))
    }

    @Test func invalidInputReturnsFailure() async throws {
        let ws = InMemoryWorkspace()
        let context = makeContext(workspace: ws)
        let writer = AnyTool(WriteFileTool())
        let result = await writer.execute(rawInput: [:], context: context)
        #expect(result.isError == true)
    }
}

@Suite("Built-in planning tools")
struct PlanningToolsTests {
    @Test func writeThenReadTodos() async throws {
        let manager = TodoManager()
        let ws = InMemoryWorkspace()
        let context = ToolExecutionContext(
            workspace: ws,
            permissionChecker: DefaultPermissionChecker(mode: .auto),
            todoManager: manager
        )

        let writer = AnyTool(WriteTodosTool())
        let write = await writer.execute(
            rawInput: [
                "todos": [
                    ["content": "first", "status": "pending"],
                    ["content": "second", "status": "in_progress"],
                ]
            ],
            context: context
        )
        #expect(write.isError == false)

        let reader = AnyTool(ReadTodosTool())
        let read = await reader.execute(rawInput: [:], context: context)
        #expect(read.output.contains("first"))
        #expect(read.output.contains("second"))
        #expect(read.output.contains("in_progress"))
    }
}
