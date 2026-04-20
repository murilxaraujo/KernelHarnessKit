import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``MessageRepository`` backed by PostgresNIO.
///
/// Messages' content blocks are stored as JSONB so the complete assistant
/// message (text + tool uses + tool results) round-trips without structural
/// loss.
public struct PostgresMessageRepository: MessageRepository, Sendable {
    public let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func append(_ message: Message, threadId: UUID) async throws {
        let encoded = try JSONEncoder().encode(message.content)
        let json = String(decoding: encoded, as: UTF8.self)
        try await client.query(
            """
            INSERT INTO khk_messages
                (id, thread_id, role, content, usage_prompt_tokens, usage_completion_tokens, created_at)
            VALUES
                (\(message.id), \(threadId), \(message.role.rawValue), \(json)::jsonb,
                 \(message.usage?.promptTokens), \(message.usage?.completionTokens), \(message.createdAt))
            """
        )
    }

    public func list(threadId: UUID) async throws -> [Message] {
        let rows = try await client.query(
            """
            SELECT id, role, content, usage_prompt_tokens, usage_completion_tokens, created_at
            FROM khk_messages
            WHERE thread_id = \(threadId)
            ORDER BY created_at
            """
        )
        var result: [Message] = []
        for try await row in rows {
            let decoded = try row.decode((UUID, String, String, Int?, Int?, Date).self)
            let content = try JSONDecoder().decode(
                [ContentBlock].self,
                from: Data(decoded.2.utf8)
            )
            let role = Role(rawValue: decoded.1) ?? .user
            let usage: UsageSnapshot? = {
                guard let p = decoded.3, let c = decoded.4 else { return nil }
                return UsageSnapshot(promptTokens: p, completionTokens: c)
            }()
            result.append(Message(
                id: decoded.0,
                threadId: threadId,
                role: role,
                content: content,
                usage: usage,
                createdAt: decoded.5
            ))
        }
        return result
    }

    public func deleteAll(threadId: UUID) async throws {
        try await client.query("DELETE FROM khk_messages WHERE thread_id = \(threadId)")
    }
}
