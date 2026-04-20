import Foundation

/// A single streaming usage snapshot from the provider.
public struct UsageSnapshot: Codable, Sendable, Hashable {
    /// Tokens consumed by the prompt (input).
    public var promptTokens: Int
    /// Tokens produced by the model (output).
    public var completionTokens: Int

    public init(promptTokens: Int = 0, completionTokens: Int = 0) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }

    /// Sum of prompt and completion tokens.
    public var totalTokens: Int { promptTokens + completionTokens }

    /// Add another snapshot into this one.
    public static func + (lhs: UsageSnapshot, rhs: UsageSnapshot) -> UsageSnapshot {
        UsageSnapshot(
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens
        )
    }
}

/// A persisted token usage record, typically written after each LLM turn.
public struct TokenUsageRecord: Codable, Sendable, Hashable, Identifiable {
    /// Unique record id.
    public let id: UUID

    /// The thread this usage belongs to.
    public let threadId: UUID

    /// The message id that produced this usage, if any.
    public let messageId: UUID?

    /// The user who owns the thread.
    public let userId: String

    /// The model that produced this usage (e.g., `"openai/gpt-4o"`).
    public let model: String

    /// Prompt token count.
    public let promptTokens: Int

    /// Completion token count.
    public let completionTokens: Int

    /// Creation timestamp.
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        threadId: UUID,
        messageId: UUID? = nil,
        userId: String,
        model: String,
        promptTokens: Int,
        completionTokens: Int,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.threadId = threadId
        self.messageId = messageId
        self.userId = userId
        self.model = model
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.createdAt = createdAt
    }

    /// Sum of prompt and completion tokens.
    public var totalTokens: Int { promptTokens + completionTokens }
}

/// Aggregated usage summary over a time range.
public struct TokenUsageSummary: Codable, Sendable, Hashable {
    /// Summed prompt tokens.
    public let promptTokens: Int
    /// Summed completion tokens.
    public let completionTokens: Int
    /// Count of records aggregated.
    public let requestCount: Int

    public init(promptTokens: Int, completionTokens: Int, requestCount: Int) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.requestCount = requestCount
    }

    /// Total tokens across all requests.
    public var totalTokens: Int { promptTokens + completionTokens }
}
