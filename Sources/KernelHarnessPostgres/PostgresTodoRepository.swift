import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``TodoRepository`` backed by PostgresNIO.
public struct PostgresTodoRepository: TodoRepository, Sendable {
    public let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func get(threadId: UUID) async throws -> [TodoItem] {
        let rows = try await client.query(
            "SELECT items FROM khk_todos WHERE thread_id = \(threadId)"
        )
        for try await row in rows {
            let decoded = try row.decode(String.self)
            return try JSONDecoder().decode([TodoItem].self, from: Data(decoded.utf8))
        }
        return []
    }

    public func replace(threadId: UUID, items: [TodoItem]) async throws {
        let json = String(
            decoding: try JSONEncoder().encode(items),
            as: UTF8.self
        )
        try await client.query(
            """
            INSERT INTO khk_todos (thread_id, items, updated_at)
            VALUES (\(threadId), \(json)::jsonb, NOW())
            ON CONFLICT (thread_id) DO UPDATE
            SET items = EXCLUDED.items, updated_at = NOW()
            """
        )
    }
}
