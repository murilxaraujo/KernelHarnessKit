import Foundation
import KernelHarnessKit
import Logging

/// A dispatched MCP response. The transport layer turns this into an HTTP
/// response (JSON body + 200 OK for regular responses, empty 202 for
/// notifications).
enum MCPResponse: Sendable {
    /// A JSON-RPC response envelope (200 OK, `application/json`).
    case json(Data)
    /// A notification was acknowledged — no response body (202 Accepted).
    case accepted
    /// A non-JSON-RPC request (e.g. `GET /mcp` probe); the transport should
    /// return 405 Method Not Allowed.
    case methodNotAllowed
}

/// Routes JSON-RPC 2.0 method calls against the MCP capability surface we
/// implement: `initialize`, `tools/list`, `tools/call`, plus the
/// `notifications/initialized` acknowledgment.
struct RPCDispatcher: Sendable {
    let serverName: String
    let serverVersion: String
    let protocolVersion: String
    let registry: ToolRegistry
    let toolBridge: ToolExecutionBridge
    let logger: Logger

    /// Handle a single inbound JSON-RPC envelope.
    func handle(body: Data) async -> MCPResponse {
        guard !body.isEmpty else {
            return .json(Self.errorEnvelope(id: nil, code: -32700, message: "parse error: empty body"))
        }

        let envelope: JSONValue
        do {
            envelope = try JSONDecoder().decode(JSONValue.self, from: body)
        } catch {
            return .json(Self.errorEnvelope(id: nil, code: -32700, message: "parse error: \(error.localizedDescription)"))
        }

        let id = envelope["id"]
        let method = envelope["method"]?.stringValue ?? ""
        let params = envelope["params"]

        logger.debug("mcp request", metadata: [
            "method": .string(method),
            "id": .string(id.map { String(describing: $0) } ?? "<none>"),
        ])

        if method.hasPrefix("notifications/") {
            return .accepted
        }

        switch method {
        case "initialize":
            return .json(Self.successEnvelope(id: id, result: .object(initializeResult())))

        case "tools/list":
            return .json(Self.successEnvelope(id: id, result: .object(SchemaAdapter.listResult(from: registry))))

        case "tools/call":
            let name = params?["name"]?.stringValue ?? ""
            let arguments = params?["arguments"]?.objectValue ?? [:]
            let result = await toolBridge.call(name: name, arguments: arguments)
            return .json(Self.successEnvelope(id: id, result: .object(result)))

        case "ping":
            return .json(Self.successEnvelope(id: id, result: .object([:])))

        default:
            logger.info("mcp unknown method", metadata: ["method": .string(method)])
            return .json(Self.errorEnvelope(id: id, code: -32601, message: "method not found: \(method)"))
        }
    }

    private func initializeResult() -> [String: JSONValue] {
        [
            "protocolVersion": .string(protocolVersion),
            "capabilities": .object([
                "tools": .object(["listChanged": .bool(false)]),
            ]),
            "serverInfo": .object([
                "name": .string(serverName),
                "version": .string(serverVersion),
            ]),
        ]
    }

    private static func successEnvelope(id: JSONValue?, result: JSONValue) -> Data {
        var envelope: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "result": result,
        ]
        envelope["id"] = id ?? .null
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }

    private static func errorEnvelope(id: JSONValue?, code: Int, message: String) -> Data {
        var envelope: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "error": .object([
                "code": .integer(Int64(code)),
                "message": .string(message),
            ]),
        ]
        envelope["id"] = id ?? .null
        return (try? JSONEncoder().encode(envelope)) ?? Data()
    }
}
