import Foundation

// MARK: - JSON-RPC primitives

enum RequestId: Codable, Hashable {
    case string(String)
    case int(Int)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let i = try? c.decode(Int.self) { self = .int(i); return }
        throw DecodingError.typeMismatch(RequestId.self, .init(codingPath: decoder.codingPath, debugDescription: "expected string or int"))
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .int(let i): try c.encode(i)
        }
    }
}

struct JSONRPCRequest: Encodable {
    let id: String
    let method: String
    let params: AnyEncodable?

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(method, forKey: .method)
        try c.encodeIfPresent(params, forKey: .params)
    }

    enum CodingKeys: String, CodingKey {
        case id, method, params
    }
}

struct JSONRPCResponse: Decodable {
    let id: RequestId
    let result: AnyCodable?
    let error: JSONRPCErrorBody?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(RequestId.self, forKey: .id)
        result = try c.decodeIfPresent(AnyCodable.self, forKey: .result)
        error = try c.decodeIfPresent(JSONRPCErrorBody.self, forKey: .error)
    }

    enum CodingKeys: String, CodingKey {
        case id, result, error
    }
}

struct JSONRPCErrorBody: Decodable {
    let code: Int
    let message: String
}

struct JSONRPCNotification: Decodable {
    let method: String
    let params: AnyCodable?
}

// MARK: - Initialize

struct InitializeParams: Encodable {
    let clientInfo: ClientInfo

    struct ClientInfo: Encodable {
        let name: String
        let version: String
        let title: String?
    }
}

struct InitializeResponse: Decodable {
    let userAgent: String
}

// MARK: - Thread

struct ThreadStartParams: Encodable {
    let model: String?
    let cwd: String?
    let approvalPolicy: String?
    let sandbox: String?
}

struct ThreadStartResponse: Decodable {
    let thread: ThreadInfo
    let model: String
    let cwd: String

    struct ThreadInfo: Decodable {
        let id: String
    }
}

// MARK: - Turn

struct UserInput: Encodable {
    let type: String
    let text: String
}

struct TurnStartParams: Encodable {
    let threadId: String
    let input: [UserInput]
    var model: String?
    var effort: String?
}

struct TurnStartResponse: Decodable {
    let turnId: String?
}

struct TurnInterruptParams: Encodable {
    let threadId: String
}

// MARK: - Events (notifications from server)

enum CodexEvent {
    case agentMessage(AgentMessageEvent)
    case turnCompleted(TurnCompletedEvent)
    case execCommandRequested(ExecCommandRequestedEvent)
    case patchApplyRequested(PatchApplyRequestedEvent)
    case error(ErrorEvent)
    case unknown(method: String, params: Any?)
}

struct AgentMessageEvent: Decodable {
    let threadId: String
    let msg: AgentMsg

    struct AgentMsg: Decodable {
        let content: [ContentItem]

        struct ContentItem: Decodable {
            let type: String
            let text: String?
        }
    }
}

struct TurnCompletedEvent: Decodable {
    let threadId: String
}

struct ExecCommandRequestedEvent: Decodable {
    let threadId: String
    let command: [String]?
    let cmdId: String?
}

struct PatchApplyRequestedEvent: Decodable {
    let threadId: String
    let patchId: String?
}

struct ErrorEvent: Decodable {
    let threadId: String?
    let message: String?
}

// MARK: - Thread List

struct ThreadListParams: Encodable {
    var cursor: String?
    var limit: Int?
    var sortKey: String?
    var cwd: String?
    var archived: Bool?
}

struct ThreadListResponse: Decodable {
    let data: [ThreadSummary]
    let nextCursor: String?
}

struct ThreadSummary: Decodable, Identifiable {
    let id: String
    let preview: String
    let modelProvider: String
    let createdAt: Int64
    let updatedAt: Int64
    let cwd: String
    let cliVersion: String
}

// MARK: - Thread Resume

struct ThreadResumeParams: Encodable {
    let threadId: String
    var cwd: String?
    var approvalPolicy: String?
    var sandbox: String?
}

struct ThreadResumeResponse: Decodable {
    let thread: ResumedThread
    let model: String
    let cwd: String
}

struct ResumedThread: Decodable {
    let id: String
    let turns: [ResumedTurn]

    private enum CodingKeys: String, CodingKey {
        case id
        case turns
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        if let decodedTurns = try? container.decodeIfPresent([ResumedTurn].self, forKey: .turns) {
            turns = decodedTurns
        } else if let flatItems = try? container.decodeIfPresent([ResumedThreadItem].self, forKey: .items),
                  !flatItems.isEmpty {
            turns = [ResumedTurn(id: "legacy-turn", items: flatItems)]
        } else {
            turns = []
        }
    }
}

struct ResumedTurn: Decodable {
    let id: String
    let items: [ResumedThreadItem]

    private enum CodingKeys: String, CodingKey {
        case id
        case items
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        items = (try? container.decodeIfPresent([ResumedThreadItem].self, forKey: .items)) ?? []
    }

    init(id: String, items: [ResumedThreadItem]) {
        self.id = id
        self.items = items
    }
}

enum ResumedThreadItem: Decodable {
    case userMessage([ResumedUserInput])
    case agentMessage(text: String, phase: String?)
    case plan(String)
    case reasoning(summary: [String], content: [String])
    case commandExecution(
        command: String,
        cwd: String,
        status: String,
        output: String?,
        exitCode: Int?,
        durationMs: Int?
    )
    case fileChange(changes: [ResumedFileUpdateChange], status: String)
    case mcpToolCall(
        server: String,
        tool: String,
        status: String,
        result: ResumedMcpToolCallResult?,
        error: ResumedMcpToolCallError?,
        durationMs: Int?
    )
    case collabAgentToolCall(
        tool: String,
        status: String,
        receiverThreadIds: [String],
        prompt: String?
    )
    case webSearch(query: String, action: AnyCodable?)
    case imageView(path: String)
    case enteredReviewMode(review: String)
    case exitedReviewMode(review: String)
    case contextCompaction
    case unknown(type: String)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case type
        case content
        case text
        case phase
        case summary
        case command
        case cwd
        case status
        case aggregatedOutput
        case output
        case exitCode
        case durationMs
        case changes
        case server
        case tool
        case result
        case error
        case receiverThreadIds
        case prompt
        case query
        case action
        case path
        case review
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = (try? container.decode(String.self, forKey: .type)) ?? ""
        switch type {
        case "userMessage":
            var content = (try? container.decodeIfPresent([ResumedUserInput].self, forKey: .content)) ?? []
            if content.isEmpty, let text = Self.decodeString(container, forKey: .text), !text.isEmpty {
                content = [ResumedUserInput(type: "text", text: text)]
            }
            self = .userMessage(content)
        case "agentMessage", "assistantMessage":
            self = .agentMessage(
                text: Self.decodeString(container, forKey: .text) ?? "",
                phase: Self.decodeString(container, forKey: .phase)
            )
        case "plan":
            self = .plan(Self.decodeString(container, forKey: .text) ?? "")
        case "reasoning":
            self = .reasoning(
                summary: Self.decodeStringArray(container, forKey: .summary),
                content: Self.decodeStringArray(container, forKey: .content)
            )
        case "commandExecution":
            self = .commandExecution(
                command: Self.decodeString(container, forKey: .command) ?? "",
                cwd: Self.decodeString(container, forKey: .cwd) ?? "",
                status: Self.decodeString(container, forKey: .status) ?? "unknown",
                output: Self.decodeString(container, forKey: .aggregatedOutput) ?? Self.decodeString(container, forKey: .output),
                exitCode: Self.decodeInt(container, forKey: .exitCode),
                durationMs: Self.decodeInt(container, forKey: .durationMs)
            )
        case "fileChange":
            self = .fileChange(
                changes: (try? container.decodeIfPresent([ResumedFileUpdateChange].self, forKey: .changes)) ?? [],
                status: Self.decodeString(container, forKey: .status) ?? "unknown"
            )
        case "mcpToolCall":
            self = .mcpToolCall(
                server: Self.decodeString(container, forKey: .server) ?? "",
                tool: Self.decodeString(container, forKey: .tool) ?? "",
                status: Self.decodeString(container, forKey: .status) ?? "unknown",
                result: try? container.decodeIfPresent(ResumedMcpToolCallResult.self, forKey: .result),
                error: try? container.decodeIfPresent(ResumedMcpToolCallError.self, forKey: .error),
                durationMs: Self.decodeInt(container, forKey: .durationMs)
            )
        case "collabAgentToolCall":
            self = .collabAgentToolCall(
                tool: Self.decodeString(container, forKey: .tool) ?? "",
                status: Self.decodeString(container, forKey: .status) ?? "unknown",
                receiverThreadIds: Self.decodeStringArray(container, forKey: .receiverThreadIds),
                prompt: Self.decodeString(container, forKey: .prompt)
            )
        case "webSearch":
            self = .webSearch(
                query: Self.decodeString(container, forKey: .query) ?? "",
                action: try? container.decodeIfPresent(AnyCodable.self, forKey: .action)
            )
        case "imageView":
            self = .imageView(path: Self.decodeString(container, forKey: .path) ?? "")
        case "enteredReviewMode":
            self = .enteredReviewMode(review: Self.decodeString(container, forKey: .review) ?? "")
        case "exitedReviewMode":
            self = .exitedReviewMode(review: Self.decodeString(container, forKey: .review) ?? "")
        case "contextCompaction":
            self = .contextCompaction
        default:
            self = .unknown(type: type.isEmpty ? "unknown" : type)
        }
    }

    private static func decodeString(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent([String].self, forKey: key) {
            return value.joined(separator: " ")
        }
        if let any = try? container.decodeIfPresent(AnyCodable.self, forKey: key) {
            return stringify(any.value)
        }
        return nil
    }

    private static func decodeStringArray(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> [String] {
        if let values = try? container.decodeIfPresent([String].self, forKey: key) {
            return values
        }
        if let any = try? container.decodeIfPresent(AnyCodable.self, forKey: key) {
            return stringifyArray(any.value)
        }
        if let value = decodeString(container, forKey: key), !value.isEmpty {
            return [value]
        }
        return []
    }

    private static func decodeInt(
        _ container: KeyedDecodingContainer<CodingKeys>,
        forKey key: CodingKeys
    ) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = decodeString(container, forKey: key), let intValue = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return intValue
        }
        return nil
    }

    private static func stringify(_ value: Any) -> String? {
        switch value {
        case let s as String:
            return s
        case let i as Int:
            return String(i)
        case let d as Double:
            return String(d)
        case let b as Bool:
            return String(b)
        case let array as [Any]:
            let values = array.compactMap { stringify($0) }
            return values.isEmpty ? nil : values.joined(separator: " ")
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                return text
            }
            return nil
        default:
            return nil
        }
    }

    private static func stringifyArray(_ value: Any) -> [String] {
        switch value {
        case let values as [String]:
            return values
        case let values as [Any]:
            return values.compactMap { stringify($0) }
        default:
            if let single = stringify(value) {
                return [single]
            }
            return []
        }
    }
}

struct ResumedUserInput: Decodable {
    let type: String
    let text: String?
    let url: String?
    let path: String?
    let name: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case url
        case path
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = (try? container.decodeIfPresent(String.self, forKey: .type)) ?? "text"
        text = try? container.decodeIfPresent(String.self, forKey: .text)
        url = try? container.decodeIfPresent(String.self, forKey: .url)
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        name = try? container.decodeIfPresent(String.self, forKey: .name)
    }

    init(type: String, text: String? = nil, url: String? = nil, path: String? = nil, name: String? = nil) {
        self.type = type
        self.text = text
        self.url = url
        self.path = path
        self.name = name
    }
}

struct ResumedFileUpdateChange: Decodable {
    let path: String
    let kind: String
    let diff: String

    private enum CodingKeys: String, CodingKey {
        case path
        case kind
        case diff
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? "unknown"
        kind = (try? container.decodeIfPresent(String.self, forKey: .kind)) ?? "update"
        diff = (try? container.decodeIfPresent(String.self, forKey: .diff)) ?? ""
    }
}

struct ResumedMcpToolCallResult: Decodable {
    let content: [AnyCodable]
    let structuredContent: AnyCodable?

    private enum CodingKeys: String, CodingKey {
        case content
        case structuredContent
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        content = (try? container.decodeIfPresent([AnyCodable].self, forKey: .content)) ?? []
        structuredContent = try? container.decodeIfPresent(AnyCodable.self, forKey: .structuredContent)
    }
}

struct ResumedMcpToolCallError: Decodable {
    let message: String

    private enum CodingKeys: String, CodingKey {
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        message = (try? container.decodeIfPresent(String.self, forKey: .message)) ?? "Unknown error"
    }
}

// MARK: - Command Exec

struct CommandExecParams: Encodable {
    let command: [String]
    var timeoutMs: Int?
    var cwd: String?
}

struct CommandExecResponse: Decodable {
    let exitCode: Int32
    let stdout: String
    let stderr: String
}

// MARK: - Helpers

struct AnyEncodable: Encodable {
    private let _encode: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        _encode = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try _encode(encoder)
    }
}

struct AnyCodable: Codable {
    let value: Any

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode([String: AnyCodable].self) {
            value = d.mapValues { $0.value }
        } else if let a = try? c.decode([AnyCodable].self) {
            value = a.map { $0.value }
        } else if let s = try? c.decode(String.self) {
            value = s
        } else if let i = try? c.decode(Int.self) {
            value = i
        } else if let d = try? c.decode(Double.self) {
            value = d
        } else if let b = try? c.decode(Bool.self) {
            value = b
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch value {
        case let s as String: try c.encode(s)
        case let i as Int: try c.encode(i)
        case let d as Double: try c.encode(d)
        case let b as Bool: try c.encode(b)
        case let a as [Any]:
            try c.encode(a.map { AnyCodable(value: $0) })
        case let d as [String: Any]:
            try c.encode(d.mapValues { AnyCodable(value: $0) })
        default: try c.encodeNil()
        }
    }

    private init(value: Any) {
        self.value = value
    }
}

// MARK: - Model List

struct ModelListParams: Encodable {
    var cursor: String?
    var limit: Int?
    var includeHidden: Bool?
}

struct ModelListResponse: Decodable {
    let data: [CodexModel]
    let nextCursor: String?
}

struct CodexModel: Decodable, Identifiable {
    let id: String
    let model: String
    let upgrade: String?
    let displayName: String
    let description: String
    let hidden: Bool
    let supportedReasoningEfforts: [ReasoningEffortOption]
    let defaultReasoningEffort: String
    let inputModalities: [String]?
    let supportsPersonality: Bool?
    let isDefault: Bool
}

struct ReasoningEffortOption: Decodable, Identifiable {
    let reasoningEffort: String
    let description: String

    var id: String { reasoningEffort }
}

// MARK: - Auth

struct LoginStartChatGPTParams: Encodable {
    let type = "chatgpt"
}

struct LoginStartApiKeyParams: Encodable {
    let type = "apiKey"
    let apiKey: String
}

struct LoginStartResponse: Decodable {
    let type: String
    let loginId: String?
    let authUrl: String?
}

struct GetAccountParams: Encodable {
    let refreshToken: Bool
}

struct GetAccountResponse: Decodable {
    let account: AccountInfo?
    let requiresOpenaiAuth: Bool

    struct AccountInfo: Decodable {
        let type: String       // "apiKey" | "chatgpt"
        let email: String?
        let planType: String?
    }
}

struct CancelLoginParams: Encodable {
    let loginId: String
}

struct AccountLoginCompletedNotification: Decodable {
    let loginId: String?
    let success: Bool
    let error: String?
}

struct AccountUpdatedNotification: Decodable {
    let authMode: String?   // "apiKey" | "chatgpt" | nil
}
