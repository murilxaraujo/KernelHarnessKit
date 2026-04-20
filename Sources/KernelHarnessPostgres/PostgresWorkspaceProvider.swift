import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``WorkspaceProvider`` that persists files in Postgres.
///
/// The workspace is scoped to a single thread — one ``PostgresWorkspaceProvider``
/// instance represents one session. All files live in the `khk_workspace_files`
/// table keyed by `(thread_id, path)`.
public struct PostgresWorkspaceProvider: WorkspaceProvider, Sendable {
    public let client: PostgresClient
    public let threadId: UUID

    public init(client: PostgresClient, threadId: UUID) {
        self.client = client
        self.threadId = threadId
    }

    public func readFile(path: String) async throws -> String {
        try validate(path)
        let rows = try await client.query(
            """
            SELECT content FROM khk_workspace_files
            WHERE thread_id = \(threadId) AND path = \(path)
            """
        )
        for try await row in rows {
            return try row.decode(String.self)
        }
        throw WorkspaceError.fileNotFound(path)
    }

    public func writeFile(path: String, content: String, source: FileSource) async throws {
        try validate(path)
        try await client.query(
            """
            INSERT INTO khk_workspace_files (thread_id, path, content, source, updated_at)
            VALUES (\(threadId), \(path), \(content), \(source.rawValue), NOW())
            ON CONFLICT (thread_id, path) DO UPDATE SET
                content = EXCLUDED.content,
                source = EXCLUDED.source,
                updated_at = NOW()
            """
        )
    }

    public func editFile(path: String, oldString: String, newString: String) async throws {
        // Read-modify-write under a transaction.
        let current = try await readFile(path: path)
        let ranges = current.ranges(of: oldString)
        guard let first = ranges.first else {
            throw WorkspaceError.stringNotFound(oldString)
        }
        guard ranges.count == 1 else {
            throw WorkspaceError.stringNotUnique(oldString)
        }
        var mutated = current
        mutated.replaceSubrange(first, with: newString)
        try await writeFile(path: path, content: mutated, source: .agent)
    }

    public func listFiles() async throws -> [WorkspaceFile] {
        let rows = try await client.query(
            """
            SELECT path, octet_length(content)::bigint, source, updated_at
            FROM khk_workspace_files
            WHERE thread_id = \(threadId)
            ORDER BY path
            """
        )
        var result: [WorkspaceFile] = []
        for try await row in rows {
            let decoded = try row.decode((String, Int64, String, Date).self)
            result.append(WorkspaceFile(
                path: decoded.0,
                sizeBytes: decoded.1,
                source: FileSource(rawValue: decoded.2) ?? .agent,
                updatedAt: decoded.3
            ))
        }
        return result
    }

    public func deleteFile(path: String) async throws {
        try validate(path)
        try await client.query(
            "DELETE FROM khk_workspace_files WHERE thread_id = \(threadId) AND path = \(path)"
        )
    }

    public func fileExists(path: String) async throws -> Bool {
        try validate(path)
        let rows = try await client.query(
            """
            SELECT 1 FROM khk_workspace_files
            WHERE thread_id = \(threadId) AND path = \(path)
            LIMIT 1
            """
        )
        for try await _ in rows { return true }
        return false
    }

    private func validate(_ path: String) throws {
        if path.isEmpty || path.contains("..") {
            throw WorkspaceError.invalidPath(path)
        }
    }
}

private extension String {
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
