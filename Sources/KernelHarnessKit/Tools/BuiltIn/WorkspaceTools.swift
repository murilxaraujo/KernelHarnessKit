import Foundation

/// Tool: `write_file` — create or overwrite a workspace file.
public struct WriteFileTool: Tool {
    public let name = "write_file"
    public let description = """
    Create or overwrite a file in the workspace. Use this to produce \
    deliverables, save intermediate results, or record notes.
    """

    public struct Input: Codable, Sendable {
        public let path: String
        public let content: String
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "path": .string(description: "Workspace-relative path, e.g. `notes.md`"),
            "content": .string(description: "Full file content"),
        ],
        required: ["path", "content"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.mutatesWorkspace]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            try await context.workspace.writeFile(
                path: input.path,
                content: input.content,
                source: .agent
            )
            return .success(
                "wrote \(input.content.utf8.count) bytes to \(input.path)",
                metadata: [
                    "path": .string(input.path),
                    "bytes": .integer(Int64(input.content.utf8.count)),
                    "operation": .string("write_file"),
                ]
            )
        } catch WorkspaceError.invalidPath(let p) {
            return .failure("invalid workspace path: \(p)", kind: .invalidInput, details: ["path": .string(p)])
        }
    }
}

/// Tool: `read_file` — read a workspace file.
public struct ReadFileTool: Tool {
    public let name = "read_file"
    public let description = "Read the content of a file in the workspace."

    public struct Input: Codable, Sendable {
        public let path: String
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "path": .string(description: "Workspace-relative path"),
        ],
        required: ["path"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            let content = try await context.workspace.readFile(path: input.path)
            return .success(
                content,
                metadata: [
                    "path": .string(input.path),
                    "bytes": .integer(Int64(content.utf8.count)),
                    "operation": .string("read_file"),
                ]
            )
        } catch WorkspaceError.fileNotFound(let p) {
            return .failure("file not found: \(p)", kind: .notFound, details: ["path": .string(p)])
        } catch WorkspaceError.invalidPath(let p) {
            return .failure("invalid workspace path: \(p)", kind: .invalidInput, details: ["path": .string(p)])
        }
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

/// Tool: `edit_file` — exact-match string replacement.
public struct EditFileTool: Tool {
    public let name = "edit_file"
    public let description = """
    Replace an exact substring in a workspace file. The `old_string` must \
    match exactly once. Prefer multiple precise edits over large rewrites.
    """

    public struct Input: Codable, Sendable {
        public let path: String
        public let oldString: String
        public let newString: String

        enum CodingKeys: String, CodingKey {
            case path
            case oldString = "old_string"
            case newString = "new_string"
        }
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "path": .string(description: "Workspace-relative path"),
            "old_string": .string(description: "Substring to replace (must match exactly once)"),
            "new_string": .string(description: "Replacement text"),
        ],
        required: ["path", "old_string", "new_string"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.mutatesWorkspace]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            try await context.workspace.editFile(
                path: input.path,
                oldString: input.oldString,
                newString: input.newString
            )
            return .success(
                "edited \(input.path)",
                metadata: [
                    "path": .string(input.path),
                    "oldBytes": .integer(Int64(input.oldString.utf8.count)),
                    "newBytes": .integer(Int64(input.newString.utf8.count)),
                    "operation": .string("edit_file"),
                ]
            )
        } catch WorkspaceError.fileNotFound(let p) {
            return .failure("file not found: \(p)", kind: .notFound, details: ["path": .string(p)])
        } catch WorkspaceError.stringNotFound {
            return .failure("old_string not found in \(input.path)", kind: .invalidInput, details: ["path": .string(input.path)])
        } catch WorkspaceError.stringNotUnique {
            return .failure("old_string appears more than once in \(input.path); make it more specific", kind: .invalidInput, details: ["path": .string(input.path)])
        } catch WorkspaceError.invalidPath(let p) {
            return .failure("invalid workspace path: \(p)", kind: .invalidInput, details: ["path": .string(p)])
        }
    }
}

/// Tool: `list_files` — enumerate workspace contents.
public struct ListFilesTool: Tool {
    public let name = "list_files"
    public let description = "List every file in the workspace with sizes and sources."

    public struct Input: Codable, Sendable {}

    public static let inputSchema = JSONSchema.object(properties: [:])

    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let files = try await context.workspace.listFiles()
        let metadata: [String: JSONValue] = [
            "count": .integer(Int64(files.count)),
            "files": .array(files.map { file in
                .object([
                    "path": .string(file.path),
                    "bytes": .integer(file.sizeBytes),
                    "source": .string(file.source.rawValue),
                ])
            }),
            "operation": .string("list_files"),
        ]
        if files.isEmpty {
            return .success("(workspace is empty)", metadata: metadata)
        }
        let rows = files.map { file in
            "\(file.path)  \(file.sizeBytes)B  [\(file.source.rawValue)]"
        }
        return .success(rows.joined(separator: "\n"), metadata: metadata)
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

/// Tool: `search_files` — find workspace file paths by substring.
public struct SearchFilesTool: Tool {
    public let name = "search_files"
    public let description = "Search workspace file paths by case-insensitive substring."

    public struct Input: Codable, Sendable {
        public let query: String
        public let limit: Int?
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "query": .string(description: "Case-insensitive path substring to search for"),
            "limit": .integer(description: "Maximum number of matches to return"),
        ],
        required: ["query"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("query is empty", kind: .invalidInput)
        }
        let limit = max(1, input.limit ?? 100)
        let files = try await context.workspace.listFiles()
        let matches = files
            .filter { $0.path.localizedCaseInsensitiveContains(query) }
            .prefix(limit)
            .map { $0 }
        let metadata: [String: JSONValue] = [
            "query": .string(query),
            "count": .integer(Int64(matches.count)),
            "truncated": .bool(matches.count < files.filter { $0.path.localizedCaseInsensitiveContains(query) }.count),
            "matches": .array(matches.map { file in
                .object([
                    "path": .string(file.path),
                    "bytes": .integer(file.sizeBytes),
                    "source": .string(file.source.rawValue),
                ])
            }),
            "operation": .string("search_files"),
        ]
        if matches.isEmpty {
            return .success("(no matching files)", metadata: metadata)
        }
        return .success(matches.map(\.path).joined(separator: "\n"), metadata: metadata)
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

/// Tool: `grep` — search workspace file contents by substring.
public struct GrepTool: Tool {
    public let name = "grep"
    public let description = "Search text contents of workspace files by case-insensitive substring."

    public struct Input: Codable, Sendable {
        public let query: String
        public let path: String?
        public let limit: Int?
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "query": .string(description: "Case-insensitive text substring to search for"),
            "path": .string(description: "Optional workspace-relative file path to search only one file"),
            "limit": .integer(description: "Maximum number of line matches to return"),
        ],
        required: ["query"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let query = input.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return .failure("query is empty", kind: .invalidInput)
        }
        let limit = max(1, input.limit ?? 100)
        let paths: [String]
        if let path = input.path, !path.isEmpty {
            paths = [path]
        } else {
            paths = try await context.workspace.listFiles().map(\.path)
        }

        var matches: [GrepMatch] = []
        do {
            for path in paths {
                let content = try await context.workspace.readFile(path: path)
                for (lineIndex, line) in content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
                    where line.localizedCaseInsensitiveContains(query)
                {
                    matches.append(GrepMatch(path: path, line: lineIndex + 1, text: String(line)))
                    if matches.count >= limit { break }
                }
                if matches.count >= limit { break }
            }
        } catch WorkspaceError.fileNotFound(let p) {
            return .failure("file not found: \(p)", kind: .notFound, details: ["path": .string(p)])
        } catch WorkspaceError.invalidPath(let p) {
            return .failure("invalid workspace path: \(p)", kind: .invalidInput, details: ["path": .string(p)])
        }

        let metadata: [String: JSONValue] = [
            "query": .string(query),
            "count": .integer(Int64(matches.count)),
            "limit": .integer(Int64(limit)),
            "matches": .array(matches.map { match in
                .object([
                    "path": .string(match.path),
                    "line": .integer(Int64(match.line)),
                    "text": .string(match.text),
                ])
            }),
            "operation": .string("grep"),
        ]
        if matches.isEmpty {
            return .success("(no matches)", metadata: metadata)
        }
        let output = matches.map { "\($0.path):\($0.line):\($0.text)" }.joined(separator: "\n")
        return .success(output, metadata: metadata)
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

private struct GrepMatch: Sendable, Hashable {
    let path: String
    let line: Int
    let text: String
}
