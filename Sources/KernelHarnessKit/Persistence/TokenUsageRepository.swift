import Foundation

/// Persistence for token usage records.
public protocol TokenUsageRepository: Sendable {
    /// Record a usage event.
    func record(_ usage: TokenUsageRecord) async throws

    /// Aggregate tokens consumed by a user since a given date.
    func summary(userId: String, since: Date) async throws -> TokenUsageSummary
}
