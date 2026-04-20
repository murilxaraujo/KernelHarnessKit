import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``TokenUsageRepository`` backed by PostgresNIO.
public struct PostgresTokenUsageRepository: TokenUsageRepository, Sendable {
    public let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func record(_ usage: TokenUsageRecord) async throws {
        try await client.query(
            """
            INSERT INTO khk_token_usage
                (id, thread_id, message_id, user_id, model,
                 prompt_tokens, completion_tokens, created_at)
            VALUES
                (\(usage.id), \(usage.threadId), \(usage.messageId), \(usage.userId),
                 \(usage.model), \(usage.promptTokens), \(usage.completionTokens), \(usage.createdAt))
            """
        )
    }

    public func summary(userId: String, since: Date) async throws -> TokenUsageSummary {
        let rows = try await client.query(
            """
            SELECT
                COALESCE(SUM(prompt_tokens)::int, 0),
                COALESCE(SUM(completion_tokens)::int, 0),
                COUNT(*)::int
            FROM khk_token_usage
            WHERE user_id = \(userId) AND created_at >= \(since)
            """
        )
        for try await row in rows {
            let decoded = try row.decode((Int, Int, Int).self)
            return TokenUsageSummary(
                promptTokens: decoded.0,
                completionTokens: decoded.1,
                requestCount: decoded.2
            )
        }
        return TokenUsageSummary(promptTokens: 0, completionTokens: 0, requestCount: 0)
    }
}
