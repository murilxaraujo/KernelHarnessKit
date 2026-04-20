import Foundation

/// Bridge between the agent's `ask_user` tool and the consumer's transport.
///
/// The engine calls ``askUser(question:)`` when the model invokes the
/// built-in `ask_user` tool. Implementations typically emit an
/// ``AgentEvent/harnessHumanInput(question:)`` on the event stream, then
/// suspend until the user submits a response via the consumer's HTTP endpoint.
///
/// ### Typical HTTP implementation
///
/// ```swift
/// actor HTTPAskUserHandler: AskUserHandler {
///     private var pending: [UUID: CheckedContinuation<String, Error>] = [:]
///
///     func askUser(question: String) async throws -> String {
///         let id = UUID()
///         return try await withCheckedThrowingContinuation { cont in
///             pending[id] = cont
///             // emit SSE event with `id`
///         }
///     }
///
///     func resolve(id: UUID, response: String) {
///         pending.removeValue(forKey: id)?.resume(returning: response)
///     }
/// }
/// ```
public protocol AskUserHandler: Sendable {
    /// Ask the user a question and wait for their response.
    func askUser(question: String) async throws -> String
}
