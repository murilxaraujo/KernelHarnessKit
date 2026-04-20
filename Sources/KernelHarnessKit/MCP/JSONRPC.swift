import Foundation

/// Minimal JSON-RPC 2.0 envelope helpers for the MCP client.
enum JSONRPC {
    /// Build a JSON-RPC request payload.
    static func request(id: Int, method: String, params: [String: JSONValue]? = nil) throws -> Data {
        var envelope: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "id": .integer(Int64(id)),
            "method": .string(method),
        ]
        if let params {
            envelope["params"] = .object(params)
        }
        return try JSONEncoder().encode(envelope)
    }

    /// Build a JSON-RPC notification payload (no `id`, no response expected).
    static func notification(method: String, params: [String: JSONValue]? = nil) throws -> Data {
        var envelope: [String: JSONValue] = [
            "jsonrpc": .string("2.0"),
            "method": .string(method),
        ]
        if let params {
            envelope["params"] = .object(params)
        }
        return try JSONEncoder().encode(envelope)
    }

    /// Parse a JSON-RPC response envelope. Throws ``MCPError/rpc(code:message:data:)``
    /// when the server signalled an error.
    static func parseResponse(_ data: Data) throws -> JSONValue {
        let value = try JSONDecoder().decode(JSONValue.self, from: data)

        if let error = value["error"], !error.isNull {
            let code = error["code"]?.intValue.map(Int.init) ?? 0
            let message = error["message"]?.stringValue ?? "unknown error"
            throw MCPError.rpc(code: code, message: message, data: error["data"])
        }
        guard let result = value["result"] else {
            throw MCPError.malformedResponse("response envelope missing 'result': \(value)")
        }
        return result
    }
}

/// Atomic counter for JSON-RPC `id` fields.
final class RequestIDCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        value += 1
        return value
    }
}
