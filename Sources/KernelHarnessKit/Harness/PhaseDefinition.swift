import Foundation

/// Context passed into phase execution closures.
public struct PhaseContext: Sendable {
    /// The session workspace. Read inputs and write outputs through it.
    public let workspace: any WorkspaceProvider

    /// The ``HarnessDefinition/type`` of the running harness.
    public let harnessType: String

    /// Index of the currently executing phase (0-based).
    public let phaseIndex: Int

    /// Total number of phases.
    public let totalPhases: Int

    /// Metadata carried across the run (consumer-supplied at construction).
    public let metadata: [String: JSONValue]

    public init(
        workspace: any WorkspaceProvider,
        harnessType: String,
        phaseIndex: Int,
        totalPhases: Int,
        metadata: [String: JSONValue] = [:]
    ) {
        self.workspace = workspace
        self.harnessType = harnessType
        self.phaseIndex = phaseIndex
        self.totalPhases = totalPhases
        self.metadata = metadata
    }
}

/// A single item in a batch phase.
public struct PhaseBatchItem: Sendable, Hashable {
    /// Stable identifier (e.g., clause index, paragraph id, document id).
    public let id: String

    /// Free-form payload — typically the text the sub-agent analyzes.
    public let content: String

    /// Extra structured metadata the sub-agent can read.
    public let metadata: [String: JSONValue]

    public init(id: String, content: String, metadata: [String: JSONValue] = [:]) {
        self.id = id
        self.content = content
        self.metadata = metadata
    }
}

/// How a phase executes.
public enum PhaseExecution: Sendable {
    /// Pure Swift — no LLM. The closure returns the string that gets written
    /// to ``PhaseDefinition/workspaceOutput`` (if any) and reported back as
    /// the phase's summary.
    case programmatic(@Sendable (PhaseContext) async throws -> String)

    /// A single LLM call. `promptBuilder` produces the user prompt; the
    /// phase's ``PhaseDefinition/systemPrompt`` is used as the system
    /// message. If `responseFormat` is set, the engine requests that format
    /// from the provider.
    case llmSingle(
        promptBuilder: @Sendable (PhaseContext) async throws -> String,
        responseFormat: ResponseFormat?
    )

    /// A multi-round agent loop. `promptBuilder` produces the initial user
    /// prompt; `maxTurns` caps the loop.
    case llmAgent(
        promptBuilder: @Sendable (PhaseContext) async throws -> String,
        maxTurns: Int
    )

    /// Fan out sub-agents per item. `itemsLoader` loads the batch from the
    /// workspace (typically from a file a prior phase produced). Each item
    /// gets its own sub-agent with a prompt built by `itemPromptBuilder`.
    /// `resultFormatter` merges per-item outputs into the single
    /// ``PhaseDefinition/workspaceOutput`` payload.
    case llmBatchAgents(
        concurrency: Int,
        itemsLoader: @Sendable (PhaseContext) async throws -> [PhaseBatchItem],
        itemPromptBuilder: @Sendable (PhaseBatchItem) -> String,
        maxTurnsPerItem: Int,
        resultFormatter: @Sendable ([BatchResult<PhaseBatchItem>]) -> String
    )

    /// Pause the harness, ask the user a question, and write their response
    /// to ``PhaseDefinition/workspaceOutput``.
    case llmHumanInput(
        questionBuilder: @Sendable (PhaseContext) async throws -> String
    )
}

/// A single phase in a harness workflow.
///
/// A phase is a focused unit of work: it reads inputs from the workspace,
/// runs one of five execution strategies (see ``PhaseExecution``), and
/// writes its output back to the workspace. The engine coordinates phase
/// progression, permission gating, and timeouts.
public struct PhaseDefinition: Sendable {
    /// Stable phase name. Used in events and as a key for cross-phase
    /// references.
    public let name: String

    /// Human-readable description.
    public let description: String

    /// The focused system prompt for this phase — 5-15 lines scoped to the
    /// phase's goal.
    public let systemPrompt: String

    /// Names of tools the phase may use. Empty set means "none". For
    /// programmatic and llmSingle phases this is typically empty.
    public let tools: Set<String>

    /// Workspace files the phase expects to read. Documented for the
    /// consumer; the engine does not enforce their presence.
    public let workspaceInputs: [String]

    /// Workspace file the phase writes its output to. `nil` to skip the
    /// write (for programmatic phases that mutate state directly).
    public let workspaceOutput: String?

    /// Per-phase timeout. `nil` disables.
    public let timeout: Duration?

    /// Optional temperature override for LLM phases.
    public let temperature: Double?

    /// Optional max tokens override for LLM phases.
    public let maxTokens: Int?

    /// The execution strategy.
    public let execution: PhaseExecution

    /// Called after the phase completes, with the phase output and workspace.
    /// Use for side effects (metrics, notifications) or for writing
    /// additional derived files.
    public let postExecute: (@Sendable (String, any WorkspaceProvider) async throws -> Void)?

    public init(
        name: String,
        description: String,
        systemPrompt: String,
        tools: Set<String> = [],
        workspaceInputs: [String] = [],
        workspaceOutput: String?,
        timeout: Duration? = .seconds(600),
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        execution: PhaseExecution,
        postExecute: (@Sendable (String, any WorkspaceProvider) async throws -> Void)? = nil
    ) {
        self.name = name
        self.description = description
        self.systemPrompt = systemPrompt
        self.tools = tools
        self.workspaceInputs = workspaceInputs
        self.workspaceOutput = workspaceOutput
        self.timeout = timeout
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.execution = execution
        self.postExecute = postExecute
    }
}
