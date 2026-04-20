import Foundation

/// A registry mapping tool names to type-erased implementations.
///
/// The registry is write-once-read-many: consumers populate it at startup and
/// then hand it to the engine. It is `Sendable` and synchronizes access with
/// an internal lock, so it can be shared across concurrent agent loops safely.
public final class ToolRegistry: @unchecked Sendable {
    private var tools: [String: AnyTool] = [:]
    private let lock = NSLock()

    public init() {}

    /// Register a concrete tool. Replaces any existing tool with the same name.
    public func register<T: Tool>(_ tool: T) {
        let any = AnyTool(tool)
        withLock { tools[any.name] = any }
    }

    /// Register a type-erased tool. Used internally by the MCP bridge.
    public func register(_ any: AnyTool) {
        withLock { tools[any.name] = any }
    }

    /// Look up a tool by name.
    public func get(_ name: String) -> AnyTool? {
        withLock { tools[name] }
    }

    /// Remove a tool by name. Returns the removed tool if one was present.
    @discardableResult
    public func unregister(_ name: String) -> AnyTool? {
        withLock { tools.removeValue(forKey: name) }
    }

    /// All registered tools, in unspecified order.
    public func allTools() -> [AnyTool] {
        withLock { Array(tools.values) }
    }

    /// The schema array to send to the LLM provider as the `tools` field.
    public func apiSchema() -> [[String: Any]] {
        withLock { tools.values.map(\.apiSchema) }
    }

    /// Return a new registry containing only the tools whose names are in
    /// `names`.
    public func filtered(allowing names: Set<String>) -> ToolRegistry {
        let child = ToolRegistry()
        withLock {
            for name in names {
                if let tool = tools[name] {
                    child.register(tool)
                }
            }
        }
        return child
    }

    /// Return a new registry containing all tools except those in `names`.
    public func filtered(excluding names: Set<String>) -> ToolRegistry {
        let child = ToolRegistry()
        withLock {
            for (name, tool) in tools where !names.contains(name) {
                child.register(tool)
            }
        }
        return child
    }

    /// `true` if a tool with the given name is registered.
    public func contains(_ name: String) -> Bool {
        withLock { tools[name] != nil }
    }

    /// Number of registered tools.
    public var count: Int {
        withLock { tools.count }
    }

    private func withLock<R>(_ body: () -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

// MARK: - Built-in tool convenience

extension ToolRegistry {
    /// Register the domain-agnostic tools shipped with KernelHarnessKit:
    /// workspace file I/O, planning (todos), and coordination (task, ask_user).
    ///
    /// Call this after constructing the registry, then add any domain-specific
    /// or MCP-bridged tools on top.
    public func registerBuiltIns() {
        register(WriteFileTool())
        register(ReadFileTool())
        register(EditFileTool())
        register(ListFilesTool())
        register(WriteTodosTool())
        register(ReadTodosTool())
        register(TaskTool())
        register(AskUserTool())
    }
}
