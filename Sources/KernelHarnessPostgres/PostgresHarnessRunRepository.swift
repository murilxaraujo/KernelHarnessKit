import Foundation
import PostgresNIO
import KernelHarnessKit

/// A ``HarnessRunRepository`` backed by PostgresNIO.
public struct PostgresHarnessRunRepository: HarnessRunRepository, Sendable {
    public let client: PostgresClient

    public init(client: PostgresClient) {
        self.client = client
    }

    public func create(_ run: HarnessRun) async throws -> HarnessRun {
        try await client.query(
            """
            INSERT INTO khk_harness_runs
                (id, thread_id, harness_type, status, current_phase_index, error_message,
                 started_at, completed_at)
            VALUES
                (\(run.id), \(run.threadId), \(run.harnessType), \(run.status.rawValue),
                 \(run.currentPhaseIndex), \(run.errorMessage), \(run.startedAt), \(run.completedAt))
            """
        )
        return run
    }

    public func get(id: UUID) async throws -> HarnessRun? {
        let rows = try await client.query(
            """
            SELECT id, thread_id, harness_type, status, current_phase_index,
                   error_message, started_at, completed_at
            FROM khk_harness_runs
            WHERE id = \(id)
            """
        )
        for try await row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    public func update(_ run: HarnessRun) async throws {
        try await client.query(
            """
            UPDATE khk_harness_runs SET
                status = \(run.status.rawValue),
                current_phase_index = \(run.currentPhaseIndex),
                error_message = \(run.errorMessage),
                completed_at = \(run.completedAt)
            WHERE id = \(run.id)
            """
        )
    }

    public func activeRun(threadId: UUID) async throws -> HarnessRun? {
        let rows = try await client.query(
            """
            SELECT id, thread_id, harness_type, status, current_phase_index,
                   error_message, started_at, completed_at
            FROM khk_harness_runs
            WHERE thread_id = \(threadId)
              AND status IN ('pending', 'running', 'paused')
            ORDER BY started_at DESC
            LIMIT 1
            """
        )
        for try await row in rows {
            return try Self.decode(row)
        }
        return nil
    }

    private static func decode(_ row: PostgresRow) throws -> HarnessRun {
        let decoded = try row.decode(
            (UUID, UUID, String, String, Int?, String?, Date, Date?).self
        )
        return HarnessRun(
            id: decoded.0,
            threadId: decoded.1,
            harnessType: decoded.2,
            status: HarnessRunStatus(rawValue: decoded.3) ?? .pending,
            currentPhaseIndex: decoded.4,
            errorMessage: decoded.5,
            startedAt: decoded.6,
            completedAt: decoded.7
        )
    }
}
