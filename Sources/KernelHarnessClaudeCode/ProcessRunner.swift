#if os(macOS) || os(Linux)
import Foundation
import Logging

/// Thin Sendable-safe wrapper around `Foundation.Process` for driving the
/// `claude -p` subprocess.
///
/// The runner is single-shot: call ``start(input:)`` to launch the process and
/// receive an async line stream of stdout plus a completion future. stderr is
/// drained to the provided logger and also captured in memory so it can be
/// surfaced in `ClaudeCodeProviderError.processFailed`.
struct ProcessRunner {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let workingDirectory: URL?
    let logger: Logger

    struct StartedProcess: Sendable {
        /// Async line stream of stdout. Finishes when the process exits.
        let stdoutLines: AsyncThrowingStream<String, Error>
        /// Awaited after stream completion to obtain exit status + stderr tail.
        let completion: @Sendable () async -> Completion
        /// Terminate the process (SIGTERM); safe to call from any task.
        let terminate: @Sendable () -> Void
        /// Write bytes to the process's stdin. After all input is written, call ``closeStdin``.
        let writeStdin: @Sendable (Data) async -> Void
        /// Close stdin so CC knows no more input is coming.
        let closeStdin: @Sendable () async -> Void
    }

    struct Completion: Sendable {
        let exitCode: Int32
        let stderrTail: String
    }

    /// Start the process.
    func start() throws -> StartedProcess {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Accumulate stderr into memory (bounded) for error reporting.
        let stderrBuffer = StderrBuffer(limit: 8 * 1024)
        let logger = self.logger
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            stderrBuffer.append(data)
            if let line = String(data: data, encoding: .utf8), !line.isEmpty {
                logger.debug("claude stderr: \(line.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        }

        try process.run()

        let stdoutLines = AsyncThrowingStream<String, Error> { continuation in
            let task = Task.detached {
                do {
                    for try await line in stdoutPipe.fileHandleForReading.bytes.lines {
                        try Task.checkCancellation()
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }

        let completion: @Sendable () async -> Completion = {
            // terminationHandler fires exactly once — synchronously if the
            // process has already exited by the time we set it, asynchronously
            // otherwise. Either way, one resume.
            await withCheckedContinuation { cc in
                process.terminationHandler = { proc in
                    let tail = stderrBuffer.tail()
                    cc.resume(returning: Completion(exitCode: proc.terminationStatus, stderrTail: tail))
                }
            }
        }

        let terminate: @Sendable () -> Void = {
            if process.isRunning {
                process.terminate()
            }
        }

        let stdinHandle = stdinPipe.fileHandleForWriting
        let writeStdin: @Sendable (Data) async -> Void = { data in
            try? stdinHandle.write(contentsOf: data)
        }
        let closeStdin: @Sendable () async -> Void = {
            try? stdinHandle.close()
        }

        return StartedProcess(
            stdoutLines: stdoutLines,
            completion: completion,
            terminate: terminate,
            writeStdin: writeStdin,
            closeStdin: closeStdin
        )
    }
}

/// Bounded in-memory stderr buffer, thread-safe via an internal lock.
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(data)
        if buffer.count > limit {
            buffer.removeFirst(buffer.count - limit)
        }
    }

    func tail() -> String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: buffer, encoding: .utf8) ?? ""
    }
}
#endif
