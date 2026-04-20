import Foundation

/// Prerequisites declared on a harness. Documented for the consumer to
/// present in UI and optionally check before starting.
public struct HarnessPrerequisites: Sendable {
    /// File path patterns the user must upload before the harness can start.
    /// The engine does not enforce these — consumer code should check, if
    /// relevant.
    public let requiredUploads: [String]

    /// A short intro message shown to the user before the first phase runs.
    public let introMessage: String

    public init(requiredUploads: [String] = [], introMessage: String = "") {
        self.requiredUploads = requiredUploads
        self.introMessage = introMessage
    }
}

/// A complete harness workflow — a named sequence of phases, plus optional
/// gatekeeper and post-harness LLM phases.
public struct HarnessDefinition: Sendable {
    /// Stable type identifier. Used to register the harness and look it up.
    public let type: String

    /// Human-readable display name.
    public let displayName: String

    /// Human-readable description.
    public let description: String

    /// Declared prerequisites.
    public let prerequisites: HarnessPrerequisites

    /// Optional pre-flight LLM phase that validates inputs and greets the
    /// user. Runs before ``phases``.
    public let gatekeeper: PhaseDefinition?

    /// The main phase sequence.
    public let phases: [PhaseDefinition]

    /// Optional wrap-up LLM phase that produces a conversational summary.
    /// Runs after ``phases`` complete successfully.
    public let postHarness: PhaseDefinition?

    public init(
        type: String,
        displayName: String,
        description: String,
        prerequisites: HarnessPrerequisites = .init(),
        gatekeeper: PhaseDefinition? = nil,
        phases: [PhaseDefinition],
        postHarness: PhaseDefinition? = nil
    ) {
        self.type = type
        self.displayName = displayName
        self.description = description
        self.prerequisites = prerequisites
        self.gatekeeper = gatekeeper
        self.phases = phases
        self.postHarness = postHarness
    }

    /// All phases in execution order — gatekeeper, main, postHarness.
    public var allPhasesInOrder: [PhaseDefinition] {
        var result: [PhaseDefinition] = []
        if let gatekeeper { result.append(gatekeeper) }
        result.append(contentsOf: phases)
        if let postHarness { result.append(postHarness) }
        return result
    }
}

/// A registry of available harnesses, keyed by ``HarnessDefinition/type``.
public final class HarnessRegistry: @unchecked Sendable {
    private var definitions: [String: HarnessDefinition] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a harness. Replaces any prior definition with the same type.
    public func register(_ definition: HarnessDefinition) {
        lock.lock(); defer { lock.unlock() }
        definitions[definition.type] = definition
    }

    /// Look up a harness by type.
    public func get(_ type: String) -> HarnessDefinition? {
        lock.lock(); defer { lock.unlock() }
        return definitions[type]
    }

    /// All registered harnesses, in unspecified order.
    public func allDefinitions() -> [HarnessDefinition] {
        lock.lock(); defer { lock.unlock() }
        return Array(definitions.values)
    }

    /// Number of registered harnesses.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return definitions.count
    }
}
