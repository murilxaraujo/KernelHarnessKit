import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``ThreadRepository`` backed by PostgresNIO.
public struct PostgresThreadRepository: ThreadRepository, Sendable {
    public typealias Thread = KernelHarnessKit.Thread

    public let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func create(_ thread: Thread) async throws -> Thread {
        try await client.query(
            """
            INSERT INTO khk_threads (id, user_id, title, status, created_at, updated_at)
            VALUES (\(thread.id), \(thread.userId), \(thread.title), \(thread.status.rawValue),
                    \(thread.createdAt), \(thread.updatedAt))
            """
        )
        return thread
    }

    public func get(id: UUID) async throws -> Thread? {
        let rows = try await client.query(
            "SELECT id, user_id, title, status, created_at, updated_at FROM khk_threads WHERE id = \(id)"
        )
        for try await row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    public func list(userId: String, status: ThreadStatus?) async throws -> [Thread] {
        let rows: PostgresRowSequence
        if let status {
            rows = try await client.query(
                """
                SELECT id, user_id, title, status, created_at, updated_at
                FROM khk_threads
                WHERE user_id = \(userId) AND status = \(status.rawValue)
                ORDER BY updated_at DESC
                """
            )
        } else {
            rows = try await client.query(
                """
                SELECT id, user_id, title, status, created_at, updated_at
                FROM khk_threads
                WHERE user_id = \(userId)
                ORDER BY updated_at DESC
                """
            )
        }
        var result: [Thread] = []
        for try await row in rows { result.append(try Self.decode(row)) }
        return result
    }

    public func update(_ thread: Thread) async throws {
        try await client.query(
            """
            UPDATE khk_threads SET
                title = \(thread.title),
                status = \(thread.status.rawValue),
                updated_at = \(thread.updatedAt)
            WHERE id = \(thread.id)
            """
        )
    }

    public func delete(id: UUID) async throws {
        try await client.query("DELETE FROM khk_threads WHERE id = \(id)")
    }

    private static func decode(_ row: PostgresRow) throws -> Thread {
        let decoded = try row.decode((UUID, String, String?, String, Date, Date).self)
        return Thread(
            id: decoded.0,
            userId: decoded.1,
            title: decoded.2,
            status: ThreadStatus(rawValue: decoded.3) ?? .active,
            createdAt: decoded.4,
            updatedAt: decoded.5
        )
    }
}
