import Testing
import Foundation
@testable import KernelHarnessKit

/// Creates a unique temp directory, runs `body` with its URL, then removes it.
private func withTempRoot<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("lfw-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

@Suite("LocalFileWorkspace")
struct LocalFileWorkspaceTests {

    @Test func readWriteDeleteRoundTripOnRealDisk() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            try await ws.writeFile(path: "a.txt", content: "hello", source: .agent)

            // Must exist on real disk under root.
            let onDisk = try String(contentsOf: root.appendingPathComponent("a.txt"), encoding: .utf8)
            #expect(onDisk == "hello")

            #expect(try await ws.fileExists(path: "a.txt"))
            #expect(try await ws.readFile(path: "a.txt") == "hello")

            try await ws.deleteFile(path: "a.txt")
            #expect(try await ws.fileExists(path: "a.txt") == false)
        }
    }

    @Test func persistenceSurvivesNewInstance() async throws {
        try await withTempRoot { root in
            try await LocalFileWorkspace(rootURL: root).writeFile(path: "p.txt", content: "persisted", source: .agent)

            // A brand-new instance pointed at the same root must see the file.
            let fresh = LocalFileWorkspace(rootURL: root)
            #expect(try await fresh.readFile(path: "p.txt") == "persisted")
        }
    }

    @Test func writeCreatesNestedDirectories() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            try await ws.writeFile(path: "src/Sub/Dir/app.swift", content: "let x = 1", source: .agent)
            #expect(try await ws.readFile(path: "src/Sub/Dir/app.swift") == "let x = 1")
        }
    }

    @Test func editReplacesOnDisk() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            try await ws.writeFile(path: "a.txt", content: "hello world", source: .agent)
            try await ws.editFile(path: "a.txt", oldString: "world", newString: "there")
            #expect(try await ws.readFile(path: "a.txt") == "hello there")
        }
    }

    @Test func listFilesReflectsDiskAndSorts() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            try await ws.writeFile(path: "z.txt", content: "z", source: .agent)
            try await ws.writeFile(path: "a.txt", content: "a", source: .agent)
            try await ws.writeFile(path: "nested/b.txt", content: "b", source: .agent)
            let paths = try await ws.listFiles().map(\.path)
            #expect(paths == ["a.txt", "nested/b.txt", "z.txt"])
        }
    }

    // MARK: Root enforcement

    @Test func rejectsDotDotTraversal() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            await #expect(throws: WorkspaceError.invalidPath("../escape.txt")) {
                try await ws.writeFile(path: "../escape.txt", content: "x", source: .agent)
            }
            await #expect(throws: WorkspaceError.invalidPath("a/../../escape")) {
                _ = try await ws.fileExists(path: "a/../../escape")
            }
            await #expect(throws: WorkspaceError.invalidPath("..")) {
                _ = try await ws.fileExists(path: "..")
            }
        }
    }

    @Test func rejectsAbsolutePathsOutsideRoot() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            await #expect(throws: WorkspaceError.invalidPath("/etc/passwd")) {
                try await ws.writeFile(path: "/etc/passwd", content: "x", source: .agent)
            }
            await #expect(throws: WorkspaceError.invalidPath("/tmp/pwned")) {
                _ = try await ws.fileExists(path: "/tmp/pwned")
            }
        }
    }

    @Test func rejectsTildeAndNul() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            await #expect(throws: WorkspaceError.invalidPath("~/.ssh/id_rsa")) {
                _ = try await ws.fileExists(path: "~/.ssh/id_rsa")
            }
            await #expect(throws: WorkspaceError.invalidPath("bad\0name")) {
                _ = try await ws.fileExists(path: "bad\0name")
            }
        }
    }

    @Test func traversalCannotEscapeRootOnDisk() async throws {
        // Even if a caller supplies a path that resolves lexically inside root,
        // symlinks pointing out of the root must be rejected/not followed.
        try await withTempRoot { root in
            let outside = FileManager.default.temporaryDirectory
                .appendingPathComponent("lfw-outside-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: outside) }
            try "secret".write(to: outside.appendingPathComponent("secret.txt"), atomically: true, encoding: .utf8)

            let linkURL = root.appendingPathComponent("link")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outside)

            let ws = LocalFileWorkspace(rootURL: root)
            // Symlinked dir should be skipped in listings and not readable.
            let paths = try await ws.listFiles().map(\.path)
            #expect(!paths.contains("link/secret.txt"))
        }
    }

    @Test func listSkipsIgnoredDirectories() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            try await ws.writeFile(path: "keep.txt", content: "k", source: .agent)
            try await ws.writeFile(path: ".build/obj/x.o", content: "bin", source: .agent)
            try await ws.writeFile(path: ".git/config", content: "[x]", source: .agent)
            let paths = try await ws.listFiles().map(\.path)
            #expect(paths == ["keep.txt"])
            #expect(!paths.contains(".build/obj/x.o"))
            #expect(!paths.contains(".git/config"))
        }
    }

    @Test func readOfMissingFileThrows() async throws {
        try await withTempRoot { root in
            let ws = LocalFileWorkspace(rootURL: root)
            await #expect(throws: WorkspaceError.fileNotFound("nope.txt")) {
                _ = try await ws.readFile(path: "nope.txt")
            }
        }
    }
}
