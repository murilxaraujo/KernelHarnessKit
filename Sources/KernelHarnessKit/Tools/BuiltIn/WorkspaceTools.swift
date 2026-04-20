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

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        try await context.workspace.writeFile(
            path: input.path,
            content: input.content,
            source: .agent
        )
        return .success("wrote \(input.content.utf8.count) bytes to \(input.path)")
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

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            let content = try await context.workspace.readFile(path: input.path)
            return .success(content)
        } catch WorkspaceError.fileNotFound(let p) {
            return .failure("file not found: \(p)")
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

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        do {
            try await context.workspace.editFile(
                path: input.path,
                oldString: input.oldString,
                newString: input.newString
            )
            return .success("edited \(input.path)")
        } catch WorkspaceError.fileNotFound(let p) {
            return .failure("file not found: \(p)")
        } catch WorkspaceError.stringNotFound {
            return .failure("old_string not found in \(input.path)")
        } catch WorkspaceError.stringNotUnique {
            return .failure("old_string appears more than once in \(input.path); make it more specific")
        }
    }
}

/// Tool: `list_files` — enumerate workspace contents.
public struct ListFilesTool: Tool {
    public let name = "list_files"
    public let description = "List every file in the workspace with sizes and sources."

    public struct Input: Codable, Sendable {}

    public static let inputSchema = JSONSchema.object(properties: [:])

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let files = try await context.workspace.listFiles()
        if files.isEmpty {
            return .success("(workspace is empty)")
        }
        let rows = files.map { file in
            "\(file.path)  \(file.sizeBytes)B  [\(file.source.rawValue)]"
        }
        return .success(rows.joined(separator: "\n"))
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}
