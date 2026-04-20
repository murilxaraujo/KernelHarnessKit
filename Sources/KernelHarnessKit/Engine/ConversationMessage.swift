import Foundation

/// The role of a message in a conversation.
public enum Role: String, Codable, Sendable, Hashable {
    /// The system prompt.
    case system
    /// A message authored by the end user.
    case user
    /// A message authored by the assistant (the LLM).
    case assistant
    /// A message carrying tool results back to the assistant.
    ///
    /// By OpenAI convention this is also represented with role `"tool"` at the
    /// API boundary; KernelHarnessKit normalizes tool results to this role.
    case tool
}

/// A single piece of message content.
///
/// A message can interleave text, images, tool invocations, and tool results.
/// This mirrors the Anthropic/OpenAI content-block model and is translated by
/// ``LLMProvider`` implementations into the vendor's native shape.
public enum ContentBlock: Sendable, Hashable {
    /// A text chunk.
    case text(String)

    /// An image, encoded as base64-addressable data with a known media type.
    case image(data: Data, mediaType: String)

    /// A tool invocation requested by the assistant.
    case toolUse(id: String, name: String, input: [String: JSONValue])

    /// The result of running a tool.
    case toolResult(toolUseId: String, content: String, isError: Bool)
}

// MARK: - Codable for ContentBlock

extension ContentBlock: Codable {
    private enum Kind: String, Codable {
        case text, image, toolUse, toolResult
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case data
        case mediaType
        case id
        case name
        case input
        case toolUseId
        case content
        case isError
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            self = .text(try c.decode(String.self, forKey: .text))
        case .image:
            let data = try c.decode(Data.self, forKey: .data)
            let mediaType = try c.decode(String.self, forKey: .mediaType)
            self = .image(data: data, mediaType: mediaType)
        case .toolUse:
            let id = try c.decode(String.self, forKey: .id)
            let name = try c.decode(String.self, forKey: .name)
            let input = try c.decodeIfPresent([String: JSONValue].self, forKey: .input) ?? [:]
            self = .toolUse(id: id, name: name, input: input)
        case .toolResult:
            let toolUseId = try c.decode(String.self, forKey: .toolUseId)
            let content = try c.decode(String.self, forKey: .content)
            let isError = try c.decodeIfPresent(Bool.self, forKey: .isError) ?? false
            self = .toolResult(toolUseId: toolUseId, content: content, isError: isError)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try c.encode(Kind.text, forKey: .kind)
            try c.encode(text, forKey: .text)
        case .image(let data, let mediaType):
            try c.encode(Kind.image, forKey: .kind)
            try c.encode(data, forKey: .data)
            try c.encode(mediaType, forKey: .mediaType)
        case .toolUse(let id, let name, let input):
            try c.encode(Kind.toolUse, forKey: .kind)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try c.encode(Kind.toolResult, forKey: .kind)
            try c.encode(toolUseId, forKey: .toolUseId)
            try c.encode(content, forKey: .content)
            try c.encode(isError, forKey: .isError)
        }
    }
}

/// A single message in a conversation.
///
/// ``ConversationMessage`` is the uniform message shape consumed by
/// ``LLMProvider`` implementations and produced by the agent loop.
public struct ConversationMessage: Codable, Sendable, Hashable {
    /// The author role.
    public let role: Role

    /// The ordered content blocks.
    public let content: [ContentBlock]

    /// Create a message.
    public init(role: Role, content: [ContentBlock]) {
        self.role = role
        self.content = content
    }

    /// Convenience initializer for a single plain-text message.
    public init(role: Role, text: String) {
        self.init(role: role, content: [.text(text)])
    }

    /// All tool invocations requested by this message (non-empty for assistant
    /// messages that triggered tool calls).
    public var toolUses: [(id: String, name: String, input: [String: JSONValue])] {
        content.compactMap { block in
            if case let .toolUse(id, name, input) = block {
                return (id, name, input)
            }
            return nil
        }
    }

    /// The concatenation of all text blocks in this message.
    public var plainText: String {
        content.reduce(into: "") { acc, block in
            if case .text(let value) = block {
                acc.append(value)
            }
        }
    }
}
