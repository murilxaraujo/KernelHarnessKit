#if os(macOS) || os(Linux)
import Foundation

/// Tool: `git_status` — inspect repository working tree status.
public struct GitStatusTool: Tool {
    public let name = "git_status"
    public let description = "Show git branch and working tree status for the workspace repository."

    public struct Input: Codable, Sendable {}

    public static let inputSchema = JSONSchema.object(properties: [:])
    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        await runGitTool(
            operation: name,
            arguments: ["status", "--short", "--branch"],
            context: context
        )
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

/// Tool: `git_diff` — inspect unstaged/staged changes.
public struct GitDiffTool: Tool {
    public let name = "git_diff"
    public let description = "Show git diff for the workspace repository. Optionally include staged changes or limit to a path."

    public struct Input: Codable, Sendable {
        public let path: String?
        public let staged: Bool?
        public let stat: Bool?
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "path": .string(description: "Optional workspace-relative path to diff"),
            "staged": .boolean(description: "Show staged diff instead of unstaged diff"),
            "stat": .boolean(description: "Show --stat summary instead of full patch"),
        ]
    )
    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        if let path = input.path, !isSafeRelativePath(path) {
            return .failure("invalid workspace path: \(path)", kind: .invalidInput, details: ["path": .string(path)])
        }
        var arguments = ["diff"]
        if input.staged == true { arguments.append("--cached") }
        if input.stat == true { arguments.append("--stat") }
        if let path = input.path, !path.isEmpty {
            arguments.append("--")
            arguments.append(path)
        }
        return await runGitTool(operation: name, arguments: arguments, context: context)
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

/// Tool: `git_log` — inspect recent commit history.
public struct GitLogTool: Tool {
    public let name = "git_log"
    public let description = "Show recent git commits for the workspace repository."

    public struct Input: Codable, Sendable {
        public let maxCount: Int?

        enum CodingKeys: String, CodingKey {
            case maxCount = "max_count"
        }
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "max_count": .integer(description: "Maximum commits to return; defaults to 10, maximum 100"),
        ]
    )
    public static let permissionRequirements: [ToolPermissionRequirement] = [.readOnly]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let maxCount = min(max(input.maxCount ?? 10, 1), 100)
        return await runGitTool(
            operation: name,
            arguments: ["log", "--oneline", "--decorate", "--max-count=\(maxCount)"],
            context: context,
            extraMetadata: ["maxCount": .integer(Int64(maxCount))]
        )
    }

    public func isReadOnly(_ input: Input) -> Bool { true }
}

private func runGitTool(
    operation: String,
    arguments: [String],
    context: ToolExecutionContext,
    extraMetadata: [String: JSONValue] = [:]
) async -> ToolResult {
    let root = gitWorkspaceRoot(from: context)
    do {
        let result = try await GitSubprocess(arguments: arguments, workingDirectory: root).run()
        var metadata: [String: JSONValue] = [
            "operation": .string(operation),
            "command": .string((["git"] + arguments).joined(separator: " ")),
            "workingDirectory": .string(root.path),
            "stdout": .string(result.stdout),
            "stderr": .string(result.stderr),
            "exitCode": .integer(Int64(result.exitCode)),
        ]
        for (key, value) in extraMetadata { metadata[key] = value }

        if result.exitCode == 0 {
            return .success(result.stdout.isEmpty ? "(empty)" : result.stdout, metadata: metadata)
        }
        let message = result.stderr.isEmpty ? "git exited with code \(result.exitCode)" : result.stderr
        return .failure(message, kind: .executionFailed, metadata: metadata)
    } catch {
        return .failure(
            "failed to run git: \(error.localizedDescription)",
            kind: .executionFailed,
            details: ["operation": .string(operation), "workingDirectory": .string(root.path)]
        )
    }
}

private func gitWorkspaceRoot(from context: ToolExecutionContext) -> URL {
    if case .string(let root)? = context.metadata["workspaceRoot"] {
        return URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
}

private func isSafeRelativePath(_ path: String) -> Bool {
    guard !path.isEmpty else { return true }
    if path.hasPrefix("/") || path.contains("..") || path.contains("\0") { return false }
    return true
}

private struct GitRunResult: Sendable, Hashable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

private struct GitSubprocess: Sendable {
    let arguments: [String]
    let workingDirectory: URL

    func run() async throws -> GitRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)
        let status = await waitForExit(process)
        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
        return GitRunResult(stdout: stdout, stderr: stderr, exitCode: status)
    }

    private func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached { (try? handle.readToEnd()) ?? Data() }.value
    }

    private func waitForExit(_ process: Process) async -> Int32 {
        await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }
}
#endif
