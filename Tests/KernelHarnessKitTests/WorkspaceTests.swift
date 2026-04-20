import Testing
import Foundation
@testable import KernelHarnessKit

@Suite("InMemoryWorkspace")
struct WorkspaceTests {
    @Test func readWriteDelete() async throws {
        let ws = InMemoryWorkspace()
        try await ws.writeFile(path: "a.txt", content: "hello", source: .agent)
        #expect(try await ws.fileExists(path: "a.txt"))
        #expect(try await ws.readFile(path: "a.txt") == "hello")

        try await ws.deleteFile(path: "a.txt")
        #expect(try await ws.fileExists(path: "a.txt") == false)
    }

    @Test func listSortsByPath() async throws {
        let ws = InMemoryWorkspace()
        try await ws.writeFile(path: "z.txt", content: "z", source: .agent)
        try await ws.writeFile(path: "a.txt", content: "a", source: .agent)
        let files = try await ws.listFiles()
        #expect(files.map(\.path) == ["a.txt", "z.txt"])
    }

    @Test func editReplacesOnce() async throws {
        let ws = InMemoryWorkspace()
        try await ws.writeFile(path: "a.txt", content: "hello world", source: .agent)
        try await ws.editFile(path: "a.txt", oldString: "world", newString: "there")
        #expect(try await ws.readFile(path: "a.txt") == "hello there")
    }

    @Test func editRejectsAmbiguousMatch() async throws {
        let ws = InMemoryWorkspace()
        try await ws.writeFile(path: "a.txt", content: "cat cat cat", source: .agent)
        await #expect(throws: WorkspaceError.stringNotUnique("cat")) {
            try await ws.editFile(path: "a.txt", oldString: "cat", newString: "dog")
        }
    }

    @Test func editRejectsMissingMatch() async throws {
        let ws = InMemoryWorkspace()
        try await ws.writeFile(path: "a.txt", content: "hello", source: .agent)
        await #expect(throws: WorkspaceError.stringNotFound("world")) {
            try await ws.editFile(path: "a.txt", oldString: "world", newString: "there")
        }
    }

    @Test func readOfMissingFileThrows() async throws {
        let ws = InMemoryWorkspace()
        await #expect(throws: WorkspaceError.fileNotFound("nope.txt")) {
            _ = try await ws.readFile(path: "nope.txt")
        }
    }

    @Test func rejectsInvalidPaths() async throws {
        let ws = InMemoryWorkspace()
        await #expect(throws: WorkspaceError.invalidPath("")) {
            _ = try await ws.fileExists(path: "")
        }
        await #expect(throws: WorkspaceError.invalidPath("../escape")) {
            _ = try await ws.fileExists(path: "../escape")
        }
    }

    @Test func seedInitializer() async throws {
        let ws = InMemoryWorkspace(seed: ["a.md": "one", "b.md": "two"])
        #expect(try await ws.readFile(path: "a.md") == "one")
        #expect(try await ws.readFile(path: "b.md") == "two")
    }
}
