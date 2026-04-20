import Foundation

/// A virtual filesystem accessible to an agent session.
///
/// Workspaces are the medium through which harness phases share context and
/// through which agents produce deliverables. Consumers implement this
/// protocol with the storage of their choice (in-memory for tests, Postgres
/// for production, local disk for CLI tools).
///
/// Implementations must be `Sendable` — they're shared across concurrent
/// `TaskGroup` children during batch execution.
public protocol WorkspaceProvider: Sendable {
    /// Read the content of the file at `path`. Throws
    /// ``WorkspaceError/fileNotFound(_:)`` if the file does not exist.
    func readFile(path: String) async throws -> String

    /// Create or overwrite the file at `path` with `content`. The file's
    /// ``FileSource`` defaults to ``FileSource/agent`` when not specified.
    func writeFile(path: String, content: String, source: FileSource) async throws

    /// Replace an exact substring in the file at `path`.
    ///
    /// Throws ``WorkspaceError/fileNotFound(_:)`` if the file does not exist
    /// or ``WorkspaceError/stringNotFound(_:)`` if `oldString` is not found.
    /// If `oldString` occurs more than once, throws
    /// ``WorkspaceError/stringNotUnique(_:)``.
    func editFile(path: String, oldString: String, newString: String) async throws

    /// List every file in the workspace.
    func listFiles() async throws -> [WorkspaceFile]

    /// Delete the file at `path`. No-op if the file doesn't exist.
    func deleteFile(path: String) async throws

    /// `true` if a file exists at `path`.
    func fileExists(path: String) async throws -> Bool
}

extension WorkspaceProvider {
    /// Convenience overload defaulting ``FileSource`` to ``FileSource/agent``.
    public func writeFile(path: String, content: String) async throws {
        try await writeFile(path: path, content: content, source: .agent)
    }
}

/// A file entry in the workspace listing.
public struct WorkspaceFile: Codable, Sendable, Hashable {
    /// File path relative to the workspace root.
    public let path: String

    /// Byte length of the current content.
    public let sizeBytes: Int64

    /// Who produced this file.
    public let source: FileSource

    /// Last-updated timestamp.
    public let updatedAt: Date

    public init(path: String, sizeBytes: Int64, source: FileSource, updatedAt: Date) {
        self.path = path
        self.sizeBytes = sizeBytes
        self.source = source
        self.updatedAt = updatedAt
    }
}

/// Who produced a workspace file.
public enum FileSource: String, Codable, Sendable, Hashable {
    /// Produced by the agent during a `write_file` or `edit_file` call.
    case agent
    /// Produced by a harness phase (e.g., via `workspaceOutput`).
    case harness
    /// Uploaded by the end user.
    case upload
}

/// Errors specific to the workspace layer.
public enum WorkspaceError: Error, Sendable, Equatable {
    /// No file exists at the given path.
    case fileNotFound(String)
    /// The target string wasn't found during an edit.
    case stringNotFound(String)
    /// The target string appears more than once; no unique match.
    case stringNotUnique(String)
    /// The given path is invalid (empty, contains `..`, etc.).
    case invalidPath(String)
}
