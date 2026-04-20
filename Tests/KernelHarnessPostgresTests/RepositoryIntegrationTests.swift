import Testing
import Foundation
import PostgresNIO
import Logging
@testable import KernelHarnessPostgres
@testable import KernelHarnessKit

/// Integration tests. Skipped unless `POSTGRES_TEST_URL` is set.
///
/// Run locally against a disposable Postgres:
///
/// ```bash
/// docker run --rm -d -p 54329:5432 \
///   -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=khk_test postgres:16
/// export POSTGRES_TEST_URL=postgres://postgres:postgres@localhost:54329/khk_test
/// swift test --filter KernelHarnessPostgresTests
/// ```
@Suite("Postgres repositories", .enabled(if: ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"] != nil))
struct RepositoryIntegrationTests {
    static func makeClient() throws -> PostgresClient {
        let raw = ProcessInfo.processInfo.environment["POSTGRES_TEST_URL"]!
        let url = URL(string: raw)!
        var tls = PostgresClient.Configuration.TLS.disable
        if url.scheme == "postgresql+ssl" || url.query?.contains("sslmode=require") == true {
            tls = try .prefer(.clientDefault)
        }
        let config = PostgresClient.Configuration(
            host: url.host ?? "localhost",
            port: url.port ?? 5432,
            username: url.user ?? "postgres",
            password: url.password,
            database: url.path.dropFirst().isEmpty ? nil : String(url.path.dropFirst()),
            tls: tls
        )
        return PostgresClient(configuration: config, backgroundLogger: Logger(label: "khk.test"))
    }

    @Test func runMigrationAndAllRepos() async throws {
        let client = try Self.makeClient()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { await client.run() }

            // Run the migration & exercise every repo.
            try await CreateAgentTables.run(on: client)

            let threads = PostgresThreadRepository(client: client)
            let messages = PostgresMessageRepository(client: client)
            let todos = PostgresTodoRepository(client: client)
            let runs = PostgresHarnessRunRepository(client: client)
            let usage = PostgresTokenUsageRepository(client: client)
            let thread = Thread(userId: "test-user", title: "integration")
            _ = try await threads.create(thread)
            let workspace = PostgresWorkspaceProvider(client: client, threadId: thread.id)

            // thread
            let loaded = try await threads.get(id: thread.id)
            #expect(loaded?.userId == "test-user")

            // messages
            let message = Message(
                threadId: thread.id,
                role: .assistant,
                content: [.text("hello"), .toolUse(id: "t1", name: "read_file", input: ["path": "x"])]
            )
            try await messages.append(message, threadId: thread.id)
            let listed = try await messages.list(threadId: thread.id)
            #expect(listed.count == 1)
            #expect(listed.first?.content.count == 2)

            // todos
            try await todos.replace(threadId: thread.id, items: [
                TodoItem(content: "one", status: .pending),
                TodoItem(content: "two", status: .inProgress),
            ])
            let fetched = try await todos.get(threadId: thread.id)
            #expect(fetched.count == 2)

            // workspace
            try await workspace.writeFile(path: "a.md", content: "hi", source: .agent)
            #expect(try await workspace.readFile(path: "a.md") == "hi")
            try await workspace.editFile(path: "a.md", oldString: "hi", newString: "hello")
            #expect(try await workspace.readFile(path: "a.md") == "hello")
            let files = try await workspace.listFiles()
            #expect(files.count == 1)

            // harness runs
            let run = HarnessRun(threadId: thread.id, harnessType: "test")
            _ = try await runs.create(run)
            #expect(try await runs.activeRun(threadId: thread.id)?.id == run.id)

            // token usage
            try await usage.record(TokenUsageRecord(
                threadId: thread.id,
                userId: "test-user",
                model: "openai/gpt-4o",
                promptTokens: 100,
                completionTokens: 50
            ))
            let summary = try await usage.summary(
                userId: "test-user",
                since: Date(timeIntervalSinceNow: -3600)
            )
            #expect(summary.totalTokens >= 150)

            // clean up
            try await threads.delete(id: thread.id)

            group.cancelAll()
        }
    }
}
