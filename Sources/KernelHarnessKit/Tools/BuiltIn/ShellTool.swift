#if os(macOS) || os(Linux)
import Foundation

/// Tool: `shell` — run a shell command in the workspace root.
public struct ShellTool: Tool {
    public let name = "shell"
    public let description = "Run a shell command in the workspace root and return stdout, stderr, exit code, and duration."

    public struct Input: Codable, Sendable {
        public let command: String
        public let timeoutSeconds: Int?

        enum CodingKeys: String, CodingKey {
            case command
            case timeoutSeconds = "timeout_seconds"
        }
    }

    public static let inputSchema = JSONSchema.object(
        properties: [
            "command": .string(description: "Shell command to run from the workspace root"),
            "timeout_seconds": .integer(description: "Timeout in seconds; defaults to 30, maximum 300"),
        ],
        required: ["command"]
    )

    public static let permissionRequirements: [ToolPermissionRequirement] = [.executesCommands]

    public init() {}

    public func execute(_ input: Input, context: ToolExecutionContext) async throws -> ToolResult {
        let command = input.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .failure("command is empty", kind: .invalidInput)
        }

        let timeoutSeconds = min(max(input.timeoutSeconds ?? 30, 1), 300)
        let root = workspaceRoot(from: context)
        let started = Date()

        do {
            let result = try await ShellSubprocess(
                command: command,
                workingDirectory: root,
                timeoutSeconds: timeoutSeconds
            ).run()
            let duration = Date().timeIntervalSince(started)
            let output = formatOutput(result: result, duration: duration)
            let metadata: [String: JSONValue] = [
                "command": .string(command),
                "workingDirectory": .string(root.path),
                "stdout": .string(result.stdout),
                "stderr": .string(result.stderr),
                "exitCode": .integer(Int64(result.exitCode)),
                "timedOut": .bool(result.timedOut),
                "durationSeconds": .number(duration),
                "operation": .string("shell"),
            ]
            if result.exitCode == 0, !result.timedOut {
                return .success(output, metadata: metadata)
            }
            let reason = result.timedOut
                ? "command timed out after \(timeoutSeconds)s"
                : "command exited with code \(result.exitCode)"
            return .failure(reason + "\n" + output, kind: .executionFailed, metadata: metadata)
        } catch {
            return .failure(
                "failed to run command: \(error.localizedDescription)",
                kind: .executionFailed,
                details: ["command": .string(command), "workingDirectory": .string(root.path)]
            )
        }
    }

    public func isReadOnly(_ input: Input) -> Bool { false }

    private func workspaceRoot(from context: ToolExecutionContext) -> URL {
        if case .string(let root)? = context.metadata["workspaceRoot"] {
            return URL(fileURLWithPath: NSString(string: root).expandingTildeInPath, isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    private func formatOutput(result: ShellRunResult, duration: TimeInterval) -> String {
        var sections: [String] = [
            "exit_code: \(result.exitCode)",
            String(format: "duration_seconds: %.3f", duration),
        ]
        if result.timedOut { sections.append("timed_out: true") }
        sections.append("stdout:\n\(result.stdout.isEmpty ? "(empty)" : result.stdout)")
        sections.append("stderr:\n\(result.stderr.isEmpty ? "(empty)" : result.stderr)")
        return sections.joined(separator: "\n")
    }
}

private struct ShellRunResult: Sendable, Hashable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
    let timedOut: Bool
}

private final class ShellSubprocess: @unchecked Sendable {
    private let command: String
    private let workingDirectory: URL
    private let timeoutSeconds: Int
    private let lock = NSLock()
    private var process: Process?

    init(command: String, workingDirectory: URL, timeoutSeconds: Int) {
        self.command = command
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }

    func run() async throws -> ShellRunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = workingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        lock.withLock { self.process = process }
        try process.run()

        async let stdoutData = readAll(stdoutPipe.fileHandleForReading)
        async let stderrData = readAll(stderrPipe.fileHandleForReading)

        let timedOut = await waitForExitOrTimeout(process: process)
        if timedOut { terminate() }
        let status = await waitForExit(process: process)

        let stdout = String(data: await stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: await stderrData, encoding: .utf8) ?? ""
        lock.withLock { self.process = nil }
        return ShellRunResult(stdout: stdout, stderr: stderr, exitCode: status, timedOut: timedOut)
    }

    private func terminate() {
        lock.withLock {
            if process?.isRunning == true { process?.terminate() }
        }
    }

    private func readAll(_ handle: FileHandle) async -> Data {
        await Task.detached {
            (try? handle.readToEnd()) ?? Data()
        }.value
    }

    private func waitForExit(process: Process) async -> Int32 {
        await Task.detached {
            process.waitUntilExit()
            return process.terminationStatus
        }.value
    }

    private func waitForExitOrTimeout(process: Process) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                process.waitUntilExit()
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(self.timeoutSeconds) * 1_000_000_000)
                return process.isRunning
            }
            let timedOut = await group.next() ?? false
            group.cancelAll()
            return timedOut
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
#endif
