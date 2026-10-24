import Foundation

/// A logical project that groups one or more concrete working locations.
public struct Project: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public var name: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(id: UUID = UUID(), name: String, createdAt: Date = .now, updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A concrete filesystem root belonging to a Project.
public struct Location: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let projectID: UUID
    public var rootURL: URL
    public var name: String?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        projectID: UUID,
        rootURL: URL,
        name: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.projectID = projectID
        self.rootURL = rootURL.standardizedFileURL
        self.name = name
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A stable, secret-free reference to a provider model.
public struct ModelRef: Codable, Sendable, Hashable {
    public let providerID: String
    public let modelID: String
    public var configuration: [String: JSONValue]

    public init(providerID: String, modelID: String, configuration: [String: JSONValue] = [:]) {
        self.providerID = providerID
        self.modelID = modelID
        self.configuration = configuration
    }
}

public enum SessionStatus: String, Codable, Sendable, Hashable {
    case active
    case archived
}

/// A durable conversation bound to one Location.
public struct Session: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let locationID: UUID
    public var title: String?
    public var status: SessionStatus
    public var defaultModel: ModelRef
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        locationID: UUID,
        title: String? = nil,
        status: SessionStatus = .active,
        defaultModel: ModelRef,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.locationID = locationID
        self.title = title
        self.status = status
        self.defaultModel = defaultModel
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum SessionMessageRole: String, Codable, Sendable, Hashable {
    case user
    case assistant
    /// A tool result. The corresponding content part must identify its ToolCall.
    case tool
}

/// Ordered, provider-neutral content in a persisted SessionMessage.
public enum SessionContentPart: Codable, Sendable, Hashable {
    case text(String)
    case image(data: Data, mediaType: String)
    case toolCall(UUID)
    case toolResult(UUID)
}

extension SessionContentPart {
    private enum CodingKeys: String, CodingKey {
        case kind, text, data, mediaType, toolCallID, toolResultID
    }

    private enum Kind: String, Codable {
        case text, image, toolCall, toolResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .image:
            self = .image(
                data: try container.decode(Data.self, forKey: .data),
                mediaType: try container.decode(String.self, forKey: .mediaType)
            )
        case .toolCall:
            self = .toolCall(try container.decode(UUID.self, forKey: .toolCallID))
        case .toolResult:
            self = .toolResult(try container.decode(UUID.self, forKey: .toolResultID))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .kind)
            try container.encode(text, forKey: .text)
        case .image(let data, let mediaType):
            try container.encode(Kind.image, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encode(mediaType, forKey: .mediaType)
        case .toolCall(let id):
            try container.encode(Kind.toolCall, forKey: .kind)
            try container.encode(id, forKey: .toolCallID)
        case .toolResult(let id):
            try container.encode(Kind.toolResult, forKey: .kind)
            try container.encode(id, forKey: .toolResultID)
        }
    }
}

public enum SessionMessageStatus: String, Codable, Sendable, Hashable {
    case inProgress
    case complete
    case failed
    case interrupted
}

/// A durable user, assistant, or tool-result message.
public struct SessionMessage: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let runID: UUID
    /// Stable order within the Session; never inferred from timestamps.
    public let sequence: Int64
    public let role: SessionMessageRole
    public var content: [SessionContentPart]
    public var status: SessionMessageStatus
    public var usage: UsageSnapshot?
    /// Monotonically increasing assistant-text checkpoint revision.
    public var checkpointRevision: Int64
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        runID: UUID,
        sequence: Int64,
        role: SessionMessageRole,
        content: [SessionContentPart],
        status: SessionMessageStatus,
        usage: UsageSnapshot? = nil,
        checkpointRevision: Int64 = 0,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.sessionID = sessionID
        self.runID = runID
        self.sequence = sequence
        self.role = role
        self.content = content
        self.status = status
        self.usage = usage
        self.checkpointRevision = checkpointRevision
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Absolute assistant text written as part of a checkpoint or terminal Run
/// transaction.
public struct AssistantTextCheckpoint: Sendable, Hashable {
    public let messageID: UUID
    public let revision: Int64
    public let accumulatedText: String

    public init(messageID: UUID, revision: Int64, accumulatedText: String) {
        self.messageID = messageID
        self.revision = revision
        self.accumulatedText = accumulatedText
    }
}

public enum SessionRunStatus: String, Codable, Sendable, Hashable {
    case running
    case awaitingApproval
    case completed
    case failed
    case cancelled
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled, .interrupted: true
        case .running, .awaitingApproval: false
        }
    }
}

public struct SessionFailure: Codable, Sendable, Hashable {
    public let code: String
    public let message: String
    public let isRetryable: Bool

    public init(code: String, message: String, isRetryable: Bool = false) {
        self.code = code
        self.message = message
        self.isRetryable = isRetryable
    }
}

public enum SessionRunOutcome: Codable, Sendable, Hashable {
    case completed
    case failed(SessionFailure)
    case cancelled
    case interrupted

    public var status: SessionRunStatus {
        switch self {
        case .completed: .completed
        case .failed: .failed
        case .cancelled: .cancelled
        case .interrupted: .interrupted
        }
    }
}

extension SessionRunOutcome {
    private enum CodingKeys: String, CodingKey { case kind, failure }
    private enum Kind: String, Codable { case completed, failed, cancelled, interrupted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .completed: self = .completed
        case .failed: self = .failed(try container.decode(SessionFailure.self, forKey: .failure))
        case .cancelled: self = .cancelled
        case .interrupted: self = .interrupted
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .completed: try container.encode(Kind.completed, forKey: .kind)
        case .failed(let failure):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(failure, forKey: .failure)
        case .cancelled: try container.encode(Kind.cancelled, forKey: .kind)
        case .interrupted: try container.encode(Kind.interrupted, forKey: .kind)
        }
    }
}

public enum SessionToolCallOutcome: Codable, Sendable, Hashable {
    case succeeded(ToolResult)
    case failed(ToolResult)
    case denied(ToolResult)
    case interrupted(ToolExecutionDisposition)
}

extension SessionToolCallOutcome {
    private enum CodingKeys: String, CodingKey { case kind, result, disposition }
    private enum Kind: String, Codable { case succeeded, failed, denied, interrupted }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .succeeded: self = .succeeded(try container.decode(ToolResult.self, forKey: .result))
        case .failed: self = .failed(try container.decode(ToolResult.self, forKey: .result))
        case .denied: self = .denied(try container.decode(ToolResult.self, forKey: .result))
        case .interrupted:
            self = .interrupted(try container.decode(ToolExecutionDisposition.self, forKey: .disposition))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded(let result):
            try container.encode(Kind.succeeded, forKey: .kind)
            try container.encode(result, forKey: .result)
        case .failed(let result):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(result, forKey: .result)
        case .denied(let result):
            try container.encode(Kind.denied, forKey: .kind)
            try container.encode(result, forKey: .result)
        case .interrupted(let disposition):
            try container.encode(Kind.interrupted, forKey: .kind)
            try container.encode(disposition, forKey: .disposition)
        }
    }
}

/// One submitted user turn. Assistant/tool messages link back through `runID`.
public struct SessionRun: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sessionID: UUID
    public let userMessageID: UUID
    public let model: ModelRef
    public var status: SessionRunStatus
    public var failure: SessionFailure?
    public let startedAt: Date
    public var completedAt: Date?

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        userMessageID: UUID,
        model: ModelRef,
        status: SessionRunStatus = .running,
        failure: SessionFailure? = nil,
        startedAt: Date = .now,
        completedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.userMessageID = userMessageID
        self.model = model
        self.status = status
        self.failure = failure
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public enum ToolCallStatus: String, Codable, Sendable, Hashable {
    case pending
    case awaitingApproval
    case running
    case succeeded
    case failed
    case denied
    case interrupted

    public var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .denied, .interrupted: true
        case .pending, .awaitingApproval, .running: false
        }
    }
}

public enum ToolExecutionDisposition: String, Codable, Sendable, Hashable {
    case notStarted
    case mayHaveExecuted
}

/// A durable tool invocation, including the model's ordering metadata.
public struct SessionToolCall: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let messageID: UUID
    public let providerCallID: String?
    public let ordinal: Int
    /// Reserved transcript order for this call's tool-result message.
    public var resultMessageSequence: Int64?
    public let name: String
    public let input: [String: JSONValue]
    public var status: ToolCallStatus
    public var permissionRequestID: UUID?
    public var result: ToolResult?
    public var executionDisposition: ToolExecutionDisposition
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        messageID: UUID,
        providerCallID: String? = nil,
        ordinal: Int,
        resultMessageSequence: Int64? = nil,
        name: String,
        input: [String: JSONValue],
        status: ToolCallStatus = .pending,
        permissionRequestID: UUID? = nil,
        result: ToolResult? = nil,
        executionDisposition: ToolExecutionDisposition = .notStarted,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.messageID = messageID
        self.providerCallID = providerCallID
        self.ordinal = ordinal
        self.resultMessageSequence = resultMessageSequence
        self.name = name
        self.input = input
        self.status = status
        self.permissionRequestID = permissionRequestID
        self.result = result
        self.executionDisposition = executionDisposition
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public enum PermissionRequestStatus: String, Codable, Sendable, Hashable {
    case pending
    case allowed
    case denied
    case cancelled
}

public enum PermissionResolution: Codable, Sendable, Hashable {
    case allow
    case deny(reason: String?)
}

extension PermissionResolution {
    private enum CodingKeys: String, CodingKey { case kind, reason }
    private enum Kind: String, Codable { case allow, deny }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .allow: self = .allow
        case .deny: self = .deny(reason: try container.decodeIfPresent(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allow: try container.encode(Kind.allow, forKey: .kind)
        case .deny(let reason):
            try container.encode(Kind.deny, forKey: .kind)
            try container.encodeIfPresent(reason, forKey: .reason)
        }
    }
}

/// A persisted approval request associated with one tool invocation.
public struct SessionPermissionRequest: Codable, Sendable, Hashable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let toolCallID: UUID
    public let toolName: String
    public let input: [String: JSONValue]
    public let reason: String?
    public var status: PermissionRequestStatus
    public var resolutionReason: String?
    public let createdAt: Date
    public var resolvedAt: Date?

    public init(
        id: UUID = UUID(),
        runID: UUID,
        toolCallID: UUID,
        toolName: String,
        input: [String: JSONValue],
        reason: String? = nil,
        status: PermissionRequestStatus = .pending,
        resolutionReason: String? = nil,
        createdAt: Date = .now,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.runID = runID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.input = input
        self.reason = reason
        self.status = status
        self.resolutionReason = resolutionReason
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}

public struct SessionSnapshot: Codable, Sendable, Hashable {
    public let session: Session
    public let messages: [SessionMessage]
    public let latestRun: SessionRun?
    public let activeRun: SessionRun?
    public let toolCalls: [SessionToolCall]
    public let pendingPermissionRequests: [SessionPermissionRequest]

    public init(
        session: Session,
        messages: [SessionMessage],
        latestRun: SessionRun?,
        activeRun: SessionRun?,
        toolCalls: [SessionToolCall],
        pendingPermissionRequests: [SessionPermissionRequest]
    ) {
        self.session = session
        self.messages = messages
        self.latestRun = latestRun
        self.activeRun = activeRun
        self.toolCalls = toolCalls
        self.pendingPermissionRequests = pendingPermissionRequests
    }
}

public struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    public let session: Session
    public let latestMessage: SessionMessage?

    public var id: UUID { session.id }

    public init(session: Session, latestMessage: SessionMessage?) {
        self.session = session
        self.latestMessage = latestMessage
    }
}
