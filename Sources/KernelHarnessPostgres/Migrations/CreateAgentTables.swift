import Foundation
import PostgresNIO
import KernelHarnessKit

/// SQL migrations for the tables that back the shipped Postgres repositories.
///
/// The migration is idempotent (uses `CREATE TABLE IF NOT EXISTS`), so calling
/// ``run(on:)`` on an already-migrated database is a no-op.
public enum CreateAgentTables {
    /// Run the migration against the given PostgresClient.
    public static func run(on client: PostgresClient) async throws {
        for statement in statements {
            try await client.query(PostgresQuery(unsafeSQL: statement))
        }
    }

    /// The SQL statements comprising the migration. Exposed for consumers
    /// who embed KernelHarnessKit into an existing migration pipeline.
    public static let statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS khk_threads (
            id UUID PRIMARY KEY,
            user_id TEXT NOT NULL,
            title TEXT,
            status TEXT NOT NULL DEFAULT 'active',
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS khk_threads_user_idx
            ON khk_threads (user_id, status, updated_at DESC)
        """,
        """
        CREATE TABLE IF NOT EXISTS khk_messages (
            id UUID PRIMARY KEY,
            thread_id UUID NOT NULL REFERENCES khk_threads(id) ON DELETE CASCADE,
            role TEXT NOT NULL,
            content JSONB NOT NULL,
            usage_prompt_tokens INTEGER,
            usage_completion_tokens INTEGER,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS khk_messages_thread_idx
            ON khk_messages (thread_id, created_at)
        """,
        """
        CREATE TABLE IF NOT EXISTS khk_todos (
            thread_id UUID PRIMARY KEY REFERENCES khk_threads(id) ON DELETE CASCADE,
            items JSONB NOT NULL DEFAULT '[]'::jsonb,
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS khk_workspace_files (
            thread_id UUID NOT NULL REFERENCES khk_threads(id) ON DELETE CASCADE,
            path TEXT NOT NULL,
            content TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT 'agent',
            updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            PRIMARY KEY (thread_id, path)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS khk_harness_runs (
            id UUID PRIMARY KEY,
            thread_id UUID NOT NULL REFERENCES khk_threads(id) ON DELETE CASCADE,
            harness_type TEXT NOT NULL,
            status TEXT NOT NULL,
            current_phase_index INTEGER,
            error_message TEXT,
            started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
            completed_at TIMESTAMPTZ
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS khk_harness_runs_thread_idx
            ON khk_harness_runs (thread_id, status, started_at DESC)
        """,
        """
        CREATE TABLE IF NOT EXISTS khk_token_usage (
            id UUID PRIMARY KEY,
            thread_id UUID NOT NULL REFERENCES khk_threads(id) ON DELETE CASCADE,
            message_id UUID,
            user_id TEXT NOT NULL,
            model TEXT NOT NULL,
            prompt_tokens INTEGER NOT NULL,
            completion_tokens INTEGER NOT NULL,
            created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
        )
        """,
        """
        CREATE INDEX IF NOT EXISTS khk_token_usage_user_idx
            ON khk_token_usage (user_id, created_at DESC)
        """,
    ]
}
