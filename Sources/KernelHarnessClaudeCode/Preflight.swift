#if os(macOS) || os(Linux)
import Foundation
import Logging

/// Verifies the local `claude` CLI install once per provider, caching the
/// result. On unknown versions it logs a warning; it never hard-fails.
actor Preflight {
    static let testedMajor: Int = 2
    static let testedMinorAtLeast: Int = 1

    private let executablePath: String
    private let logger: Logger
    private var cached: Result<String, Error>?

    init(executablePath: String, logger: Logger) {
        self.executablePath = executablePath
        self.logger = logger
    }

    /// Returns the version string (e.g. `"2.1.118"`) on success. Logs a
    /// warning when the version is outside the tested matrix but does not
    /// throw — compatibility is advisory.
    func version() throws -> String {
        if let cached {
            switch cached {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }
        do {
            let output = try runVersion()
            let version = parseVersion(output)
            warnIfOutsideTestedMatrix(version)
            cached = .success(version)
            return version
        } catch {
            cached = .failure(error)
            throw error
        }
    }

    private func runVersion() throws -> String {
        let process = Process()
        if executablePath.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["--version"]
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executablePath, "--version"]
        }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw ClaudeCodeProviderError.binaryNotFound(path: executablePath)
        }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw ClaudeCodeProviderError.binaryNotFound(path: executablePath)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func parseVersion(_ output: String) -> String {
        // Example: "2.1.118 (Claude Code)" — take first whitespace-separated token.
        output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ")
            .first
            .map(String.init) ?? output
    }

    private func warnIfOutsideTestedMatrix(_ version: String) {
        let components = version.split(separator: ".").compactMap { Int($0) }
        guard components.count >= 2 else {
            logger.warning("Unable to parse claude version: \(version)")
            return
        }
        let major = components[0]
        let minor = components[1]
        if major != Self.testedMajor || minor < Self.testedMinorAtLeast {
            logger.warning(
                "claude version \(version) is outside the tested matrix (expected \(Self.testedMajor).\(Self.testedMinorAtLeast).x+). Proceeding; schema drift may cause errors."
            )
        }
    }
}
#endif
