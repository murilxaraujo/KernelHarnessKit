import Foundation
import KernelHarnessKit
import Logging
#if canImport(KernelHarnessMCPServer)
import KernelHarnessMCPServer
#endif

extension ClaudeCodeProvider {
    /// A preset that drives the locally installed Claude Code CLI, assuming
    /// Max subscription OAuth auth is already configured via `claude auth login`.
    ///
    /// - Parameters:
    ///   - mcpServer: The live MCP server whose tools CC should see natively.
    ///     Pass `nil` for a text-only invocation.
    ///   - extraFlags: Additional flags forwarded to `claude`.
    ///   - logger: Logger used for stderr drain and version warnings.
    public static func local(
        mcpServer: MCPServerHandle? = nil,
        extraFlags: [String] = [],
        logger: Logger = Logger(label: "khk.claude-code")
    ) -> ClaudeCodeProvider {
        ClaudeCodeProvider(
            mcpServer: mcpServer,
            extraFlags: extraFlags,
            logger: logger
        )
    }
}
