import Foundation
import KernelHarnessKit
import Logging
#if canImport(KernelHarnessMCPServer)
import KernelHarnessMCPServer
#endif

/// An ``LLMProvider`` that routes completions through the locally installed
/// Claude Code CLI, reusing whatever authentication the CLI has configured
/// (Max subscription via OAuth, Anthropic API key, Bedrock, Vertex).
///
/// ### Tool-execution modes
///
/// * **No MCP server (`mcpServer == nil`)** — CC is invoked with
///   `--max-turns 1` and all built-in tools disabled. The model can only
///   emit text or `tool_use` blocks; the provider returns the assistant
///   message verbatim and KernelHarnessKit's ``AgentLoop`` is responsible
///   for executing any tool_use blocks via its own ``ToolRegistry``.
///
/// * **With an `MCPServerHandle`** (recommended) — CC runs its own
///   model ↔ tool ↔ model loop up to ``maxInternalTurns`` per
///   invocation. Tools appear to the model as
///   `mcp__<server-name>__<tool-name>` and every invocation is served by the
///   in-process ``MCPServer`` you passed in, which in turn dispatches through
///   your `ToolRegistry` and `PermissionChecker`. The final message the
///   provider returns to KHK is the post-tool assistant text with no leaked
///   `tool_use` blocks (KHK would otherwise execute them a second time).
///
/// ### Session reuse
///
/// The provider currently spawns a fresh `claude -p` per `streamChat` call.
/// Because CC owns the entire tool loop (above), a "single streamChat" often
/// already encompasses many model turns, tool calls, and the model's final
/// response — so per-call cold-start is usually an acceptable fixed cost.
/// Long-lived process reuse (keeping one CC process alive across KHK
/// `.llmAgent` turns via stream-json stdin REPL) is a deliberate follow-up,
/// not a current guarantee.
///
/// ### Example
///
/// ```swift
/// let registry = ToolRegistry()
/// registry.registerBuiltIns()
///
/// let mcpServer = MCPServer(
///     toolRegistry: registry,
///     contextFactory: {
///         ToolExecutionContext(
///             workspace: InMemoryWorkspace(),
///             permissionChecker: AllowAllPermissionChecker()
///         )
///     }
/// )
/// let mcpHandle = try await mcpServer.start()
///
/// let provider = ClaudeCodeProvider(mcpServer: mcpHandle)
///
/// let registry = ProviderRegistry(providers: ["claude": provider])
/// ```
///
/// ### Platform support
///
/// The provider requires `Foundation.Process` and therefore only runs on
/// macOS and Linux. Using it on iOS/tvOS/watchOS throws
/// ``ClaudeCodeProviderError/unsupportedPlatform``.
public struct ClaudeCodeProvider: LLMProvider {
    /// Path to the `claude` binary. Defaults to `claude` (resolved via
    /// `/usr/bin/env`). Pass an absolute path to skip PATH lookup.
    public let executablePath: String

    /// The MCP server whose tools CC should be configured to see. When `nil`,
    /// CC is invoked with no MCP config and `--tools ""` (it has no tools).
    public let mcpServer: MCPServerHandle?

    /// Flags appended to every `claude` invocation, after the provider's
    /// own flags. Useful for `--debug` or for forwarding custom MCP configs.
    public let extraFlags: [String]

    /// Working directory to spawn CC in. When `nil`, the provider creates a
    /// fresh ephemeral directory per call so CC's CLAUDE.md auto-discovery
    /// finds nothing.
    public let workingDirectoryOverride: URL?

    /// When `true`, remove `ANTHROPIC_API_KEY` from the spawned process's
    /// environment so CC falls back to the keychain-stored Max OAuth token.
    /// Defaults to `true` — that's the whole point of this provider.
    public let preferMaxOAuth: Bool

    /// Upper bound on turns within a single CC invocation when MCP tools are
    /// configured. CC runs its own model ↔ tool ↔ model loop, so we need
    /// enough turns for the model's final response after tool execution.
    /// Ignored when `mcpServer` is `nil`.
    public let maxInternalTurns: Int

    let logger: Logger
    #if os(macOS) || os(Linux)
    let preflight: Preflight
    #endif

    public init(
        executablePath: String = "claude",
        mcpServer: MCPServerHandle? = nil,
        extraFlags: [String] = [],
        workingDirectory: URL? = nil,
        preferMaxOAuth: Bool = true,
        maxInternalTurns: Int = 20,
        logger: Logger = Logger(label: "khk.claude-code")
    ) {
        self.executablePath = executablePath
        self.mcpServer = mcpServer
        self.extraFlags = extraFlags
        self.workingDirectoryOverride = workingDirectory
        self.preferMaxOAuth = preferMaxOAuth
        self.maxInternalTurns = maxInternalTurns
        self.logger = logger
        #if os(macOS) || os(Linux)
        self.preflight = Preflight(executablePath: executablePath, logger: logger)
        #endif
    }

    public func streamChat(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        tools: [[String: Any]]?,
        responseFormat: ResponseFormat?,
        temperature: Double?,
        maxTokens: Int?
    ) -> AsyncThrowingStream<StreamChunk, Error> {
        #if os(macOS) || os(Linux)
        return AsyncThrowingStream<StreamChunk, Error> { continuation in
            let task = Task {
                do {
                    try await runOneTurn(
                        model: model,
                        messages: messages,
                        systemPrompt: systemPrompt,
                        continuation: continuation
                    )
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        #else
        return AsyncThrowingStream { continuation in
            continuation.finish(throwing: ClaudeCodeProviderError.unsupportedPlatform)
        }
        #endif
    }

    #if os(macOS) || os(Linux)
    private func runOneTurn(
        model: String,
        messages: [ConversationMessage],
        systemPrompt: String?,
        continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    ) async throws {
        _ = try await preflight.version()

        let (runner, workdir) = try buildRunner(model: model, systemPrompt: systemPrompt, messages: messages)
        let started = try runner.start()
        defer {
            if let workdir { try? FileManager.default.removeItem(at: workdir) }
        }

        // Feed the history as NDJSON lines on stdin, then close.
        let lines = try ConversationSerialization.streamJSONLines(for: messages)
        for line in lines {
            var payload = line
            payload.append(0x0A) // newline
            await started.writeStdin(payload)
        }
        await started.closeStdin()

        // CC may run multiple model turns within a single invocation when MCP
        // tools are configured (model → tool_use → tool_result → model again
        // → …). The final assistant message KHK cares about is the one after
        // the *last* tool round — i.e. the message with `stop_reason: end_turn`.
        //
        // We therefore track accumulators *per model turn*: on `message_start`
        // we reset, on intermediate `messageStop` we discard (the message
        // contained only intermediate tool_use blocks that CC already
        // executed), and only the accumulators from the last model turn are
        // emitted as the final `.messageComplete`.
        var currentText = ""
        var currentBlocks: [ContentBlock] = []
        var currentToolUses = ToolUseAccumulator()
        var currentOpen: [Int: BlockKind] = [:]
        var finalText = ""
        var finalBlocks: [ContentBlock] = []
        var usage: UsageSnapshot?
        var terminalError: (message: String, subtype: String?)?
        var nextToolCallIndex: Int = 0

        func commitCurrentTurn() {
            var blocks: [ContentBlock] = []
            if !currentText.isEmpty { blocks.append(.text(currentText)) }
            blocks.append(contentsOf: currentBlocks)
            finalText = currentText
            finalBlocks = blocks
        }

        func resetCurrentTurn() {
            currentText = ""
            currentBlocks = []
            currentToolUses = ToolUseAccumulator()
            currentOpen = [:]
        }

        do {
            for try await line in started.stdoutLines {
                try Task.checkCancellation()
                let event = CLIEventClassifier.classify(line: line)
                switch event {
                case .initMetadata(let sessionId, let apiKeySource):
                    logger.debug("cc session", metadata: [
                        "sessionId": .string(sessionId),
                        "apiKeySource": .string(apiKeySource),
                    ])

                case .messageStart:
                    resetCurrentTurn()

                case .textDelta(let text):
                    currentText.append(text)
                    continuation.yield(.textDelta(text))

                case .thinkingDelta:
                    break

                case .toolUseStart(let index, let id, let name):
                    currentOpen[index] = .toolUse
                    let localName = stripMCPPrefix(name)
                    currentToolUses.begin(index: index, id: id, name: localName)
                    continuation.yield(.toolCallDelta(
                        index: nextToolCallIndex,
                        id: id,
                        name: localName,
                        argumentsChunk: nil
                    ))
                    nextToolCallIndex += 1

                case .toolUseInputDelta(let index, let partialJSON):
                    currentToolUses.append(index: index, partialJSON: partialJSON)
                    continuation.yield(.toolCallDelta(
                        index: index,
                        id: nil,
                        name: nil,
                        argumentsChunk: partialJSON
                    ))

                case .blockStop(let index):
                    if currentOpen[index] == .toolUse,
                       let block = currentToolUses.finalize(index: index) {
                        currentBlocks.append(block)
                    }
                    currentOpen[index] = nil

                case .messageStop:
                    // The current assistant turn is complete. Save its blocks
                    // as the tentative final; a subsequent `message_start`
                    // will overwrite them if CC runs another model turn.
                    commitCurrentTurn()

                case .toolResultIngested(let id, let content, let isError):
                    logger.info("cc executed mcp tool", metadata: [
                        "toolUseId": .string(id),
                        "isError": .stringConvertible(isError),
                        "contentPreview": .string(String(content.prefix(200))),
                    ])

                case .rateLimit(let resetsAt, let type):
                    logger.info("cc rate limit", metadata: [
                        "resetsAt": .stringConvertible(resetsAt),
                        "type": .string(type),
                    ])

                case .turnResult(let success, let resultUsage, let errorMessage, let subtype):
                    usage = resultUsage
                    if !success {
                        terminalError = (errorMessage ?? "claude cli failed", subtype)
                    }

                case .ignored:
                    break
                }
            }
        } catch is CancellationError {
            started.terminate()
            throw CancellationError()
        }

        let completion = await started.completion()
        if let err = terminalError {
            if isAuthFailure(message: err.message, stderr: completion.stderrTail) {
                throw ClaudeCodeProviderError.notAuthenticated(detail: err.message)
            }
            var parts: [String] = [err.message]
            if let sub = err.subtype, !sub.isEmpty { parts.append("subtype: \(sub)") }
            if !completion.stderrTail.isEmpty {
                parts.append("stderr: \(completion.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            throw ClaudeCodeProviderError.cliError(message: parts.joined(separator: " | "))
        }
        if completion.exitCode != 0 {
            throw ClaudeCodeProviderError.processFailed(
                exitCode: completion.exitCode,
                stderrTail: completion.stderrTail
            )
        }

        // When MCP is configured CC ran the full tool loop internally; any
        // tool_use blocks in `finalBlocks` were already executed by CC, so
        // returning them would cause KHK's AgentLoop to execute them a second
        // time. Strip them in that mode. In the no-MCP mode we keep them
        // because KHK's AgentLoop is the one that will execute them.
        let emitBlocks: [ContentBlock]
        if mcpServer != nil {
            let withoutToolUses = finalBlocks.filter { block in
                if case .toolUse = block { return false }
                return true
            }
            emitBlocks = withoutToolUses.isEmpty && !finalText.isEmpty
                ? [.text(finalText)]
                : withoutToolUses
        } else {
            emitBlocks = finalBlocks
        }

        let message = ConversationMessage(role: .assistant, content: emitBlocks)
        continuation.yield(.messageComplete(message, usage ?? UsageSnapshot(promptTokens: 0, completionTokens: 0)))
        continuation.finish()
    }

    private func isAuthFailure(message: String, stderr: String) -> Bool {
        let haystacks = [message.lowercased(), stderr.lowercased()]
        let needles = ["authentication", "credentials", "credit balance is too low", "unauthorized", "oauth"]
        return haystacks.contains(where: { h in needles.contains(where: h.contains) })
    }

    private func buildRunner(
        model: String,
        systemPrompt: String?,
        messages: [ConversationMessage]
    ) throws -> (ProcessRunner, URL?) {
        let turnsForInvocation = mcpServer == nil ? 1 : maxInternalTurns
        var args: [String] = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--max-turns", String(turnsForInvocation),
            "--no-session-persistence",
            "--strict-mcp-config",
            "--disable-slash-commands",
            "--tools", "",
            "--permission-mode", "bypassPermissions",
        ]
        if let handle = mcpServer {
            args.append(contentsOf: ["--mcp-config", handle.mcpConfigJSON])
        }
        if !model.isEmpty {
            args.append(contentsOf: ["--model", model])
        }
        if let composed = ConversationSerialization.combinedSystemPrompt(messages: messages, explicit: systemPrompt) {
            args.append(contentsOf: ["--system-prompt", composed])
        }
        args.append(contentsOf: extraFlags)

        var environment = ProcessInfo.processInfo.environment
        if preferMaxOAuth {
            environment.removeValue(forKey: "ANTHROPIC_API_KEY")
        }

        var ephemeralDir: URL?
        let workingDirectory: URL
        if let override = workingDirectoryOverride {
            workingDirectory = override
        } else {
            let url = try ephemeralDirectory()
            workingDirectory = url
            ephemeralDir = url
        }

        let (resolvedExecutable, wrapperArgs) = resolveExecutable(path: executablePath, args: args)

        let runner = ProcessRunner(
            executable: resolvedExecutable,
            arguments: wrapperArgs,
            environment: environment,
            workingDirectory: workingDirectory,
            logger: logger
        )
        return (runner, ephemeralDir)
    }

    private func resolveExecutable(path: String, args: [String]) -> (String, [String]) {
        if path.hasPrefix("/") {
            return (path, args)
        }
        // Use env trampoline to honor PATH.
        return ("/usr/bin/env", [path] + args)
    }

    private func ephemeralDirectory() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("khk-cc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func stripMCPPrefix(_ toolName: String) -> String {
        guard let handle = mcpServer else { return toolName }
        let prefix = "mcp__\(handle.name)__"
        if toolName.hasPrefix(prefix) {
            return String(toolName.dropFirst(prefix.count))
        }
        return toolName
    }

    private enum BlockKind {
        case toolUse
    }
    #endif
}
