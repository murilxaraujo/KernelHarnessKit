import Foundation

/// A ``WorkspaceProvider`` that stores files in an in-memory actor.
///
/// Suitable for tests, ephemeral sessions, and the demo CLI. Production
/// deployments should use the Postgres-backed implementation shipped in
/// the `KernelHarnessPostgres` target.
public actor InMemoryWorkspace: WorkspaceProvider {
    private struct Entry {
        var content: String
        var source: FileSource
        var updatedAt: Date
    }

    private var files: [String: Entry] = [:]

    public init() {}

    /// Seed the workspace with an initial set of files. Useful for tests.
    public init(seed: [String: String], source: FileSource = .upload) {
        for (path, content) in seed {
            files[path] = Entry(content: content, source: source, updatedAt: Date())
        }
    }

    public func readFile(path: String) async throws -> String {
        try validate(path)
        guard let entry = files[path] else {
            throw WorkspaceError.fileNotFound(path)
        }
        return entry.content
    }

    public func writeFile(path: String, content: String, source: FileSource) async throws {
        try validate(path)
        files[path] = Entry(content: content, source: source, updatedAt: Date())
    }

    public func editFile(path: String, oldString: String, newString: String) async throws {
        try validate(path)
        guard var entry = files[path] else {
            throw WorkspaceError.fileNotFound(path)
        }
        let ranges = entry.content.ranges(of: oldString)
        guard let range = ranges.first else {
            throw WorkspaceError.stringNotFound(oldString)
        }
        guard ranges.count == 1 else {
            throw WorkspaceError.stringNotUnique(oldString)
        }
        entry.content.replaceSubrange(range, with: newString)
        entry.updatedAt = Date()
        files[path] = entry
    }

    public func listFiles() async throws -> [WorkspaceFile] {
        files
            .map { path, entry in
                WorkspaceFile(
                    path: path,
                    sizeBytes: Int64(entry.content.utf8.count),
                    source: entry.source,
                    updatedAt: entry.updatedAt
                )
            }
            .sorted { $0.path < $1.path }
    }

    public func deleteFile(path: String) async throws {
        try validate(path)
        files.removeValue(forKey: path)
    }

    public func fileExists(path: String) async throws -> Bool {
        try validate(path)
        return files[path] != nil
    }

    private func validate(_ path: String) throws {
        if path.isEmpty || path.contains("..") {
            throw WorkspaceError.invalidPath(path)
        }
    }
}

private extension String {
    /// All ranges at which `substring` occurs.
    func ranges(of substring: String) -> [Range<String.Index>] {
        guard !substring.isEmpty else { return [] }
        var results: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let range = range(of: substring, range: searchStart..<endIndex)
        {
            results.append(range)
            searchStart = range.upperBound
        }
        return results
    }
}
