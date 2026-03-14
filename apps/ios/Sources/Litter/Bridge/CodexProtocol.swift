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
    let capabilities: InitializeCapabilities?

    struct ClientInfo: Encodable {
        let name: String
        let version: String
        let title: String?
    }

    struct InitializeCapabilities: Encodable {
        let experimentalApi: Bool
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
    let dynamicTools: [DynamicToolSpec]?
    let persistExtendedHistory: Bool? = true
}

struct ThreadStartResponse: Decodable {
    let thread: ThreadInfo
    let model: String
    let modelProvider: String?
    let cwd: String
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case thread
        case model
        case modelProvider
        case modelProviderSnake = "model_provider"
        case cwd
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(ThreadInfo.self, forKey: .thread)
        model = try container.decode(String.self, forKey: .model)
        modelProvider = (try? container.decodeIfPresent(String.self, forKey: .modelProvider))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelProviderSnake))
        cwd = try container.decode(String.self, forKey: .cwd)
        reasoningEffort = (try? container.decodeIfPresent(String.self, forKey: .reasoningEffort))
            ?? (try? container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake))
    }

    struct ThreadInfo: Decodable {
        let id: String
        let path: String?
        let parentThreadId: String?
        let rootThreadId: String?
        let agentId: String?
        let agentNickname: String?
        let agentRole: String?

        private enum CodingKeys: String, CodingKey {
            case id
            case path
            case parentThreadId
            case parentThreadIdSnake = "parent_thread_id"
            case forkedFromId
            case forkedFromIdSnake = "forked_from_id"
            case rootThreadId
            case rootThreadIdSnake = "root_thread_id"
            case agentId
            case agentIdSnake = "agent_id"
            case agentNickname
            case agentNicknameSnake = "agent_nickname"
            case agentRole
            case agentRoleSnake = "agent_role"
            case agentType
            case agentTypeSnake = "agent_type"
            case source
        }

        private struct SourcePayload: Decodable {
            let threadSpawn: ThreadSpawn?

            private enum CodingKeys: String, CodingKey {
                case threadSpawn
                case threadSpawnSnake = "thread_spawn"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                threadSpawn = (try? container.decodeIfPresent(ThreadSpawn.self, forKey: .threadSpawn))
                    ?? (try? container.decodeIfPresent(ThreadSpawn.self, forKey: .threadSpawnSnake))
            }
        }

        private struct ThreadSpawn: Decodable {
            let agentId: String?
            let agentNickname: String?
            let agentRole: String?

            private enum CodingKeys: String, CodingKey {
                case agentId
                case agentIdSnake = "agent_id"
                case agentNickname
                case agentNicknameSnake = "agent_nickname"
                case agentRole
                case agentRoleSnake = "agent_role"
                case agentType
                case agentTypeSnake = "agent_type"
            }

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                let agentIdPrimary = try? container.decodeIfPresent(String.self, forKey: .agentId)
                let agentIdSnake = try? container.decodeIfPresent(String.self, forKey: .agentIdSnake)
                agentId = agentIdPrimary ?? agentIdSnake

                let nicknamePrimary = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
                let nicknameSnake = try? container.decodeIfPresent(String.self, forKey: .agentNicknameSnake)
                agentNickname = nicknamePrimary ?? nicknameSnake

                let rolePrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
                let roleSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
                let roleType = try? container.decodeIfPresent(String.self, forKey: .agentType)
                let roleTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
                agentRole = rolePrimary ?? roleSnake ?? roleType ?? roleTypeSnake
            }
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            path = try? container.decodeIfPresent(String.self, forKey: .path)

            let source = try? container.decodeIfPresent(SourcePayload.self, forKey: .source)

            let parentFromPrimary = try? container.decodeIfPresent(String.self, forKey: .parentThreadId)
            let parentFromSnake = try? container.decodeIfPresent(String.self, forKey: .parentThreadIdSnake)
            let parentFromForkCamel = try? container.decodeIfPresent(String.self, forKey: .forkedFromId)
            let parentFromForkSnake = try? container.decodeIfPresent(String.self, forKey: .forkedFromIdSnake)
            parentThreadId = Self.sanitized(parentFromPrimary ?? parentFromSnake ?? parentFromForkCamel ?? parentFromForkSnake)

            let rootFromPrimary = try? container.decodeIfPresent(String.self, forKey: .rootThreadId)
            let rootFromSnake = try? container.decodeIfPresent(String.self, forKey: .rootThreadIdSnake)
            rootThreadId = Self.sanitized(rootFromPrimary ?? rootFromSnake)

            let directAgentIdPrimary = try? container.decodeIfPresent(String.self, forKey: .agentId)
            let directAgentIdSnake = try? container.decodeIfPresent(String.self, forKey: .agentIdSnake)
            let directAgentId = directAgentIdPrimary ?? directAgentIdSnake

            let directNicknamePrimary = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
            let directNicknameSnake = try? container.decodeIfPresent(String.self, forKey: .agentNicknameSnake)
            let directNickname = directNicknamePrimary ?? directNicknameSnake

            let directRolePrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
            let directRoleSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
            let directRoleType = try? container.decodeIfPresent(String.self, forKey: .agentType)
            let directRoleTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
            let directRole = directRolePrimary ?? directRoleSnake ?? directRoleType ?? directRoleTypeSnake
            agentId = Self.sanitized(directAgentId)
                ?? Self.sanitized(source?.threadSpawn?.agentId)
            agentNickname = Self.sanitized(directNickname)
                ?? Self.sanitized(source?.threadSpawn?.agentNickname)
            agentRole = Self.sanitized(directRole)
                ?? Self.sanitized(source?.threadSpawn?.agentRole)
        }

        private static func sanitized(_ value: String?) -> String? {
            guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
            return raw
        }
    }

}

// MARK: - Turn

struct UserInput: Encodable {
    let type: String
    var text: String?
    var path: String?
    var name: String?
    var imageURL: String?

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case path
        case name
        case imageURL = "image_url"
    }

    init(type: String, text: String? = nil, path: String? = nil, name: String? = nil, imageURL: String? = nil) {
        self.type = type
        self.text = text
        self.path = path
        self.name = name
        self.imageURL = imageURL
    }
}

struct TurnStartParams: Encodable {
    let threadId: String
    let input: [UserInput]
    var model: String?
    var effort: String?
}

struct TurnStartResponse: Decodable {
    struct Turn: Decodable { let id: String }
    let turn: Turn?

    var turnId: String? { turn?.id }
}

struct TurnInterruptParams: Encodable {
    let threadId: String
    let turnId: String
}

// MARK: - Review

struct ReviewStartParams: Encodable {
    let threadId: String
    let target: ReviewTarget
    var delivery: String?
}

enum ReviewTarget: Encodable {
    case uncommittedChanges

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

struct ReviewStartResponse: Decodable {
    let reviewThreadId: String?
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
    let path: String?
    let cliVersion: String
    let parentThreadId: String?
    let rootThreadId: String?
    let agentId: String?
    let agentNickname: String?
    let agentRole: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case preview
        case name
        case modelProvider
        case modelProviderSnake = "model_provider"
        case createdAt
        case createdAtSnake = "created_at"
        case updatedAt
        case updatedAtSnake = "updated_at"
        case cwd
        case path
        case cliVersion
        case cliVersionSnake = "cli_version"
        case parentThreadId
        case parentThreadIdSnake = "parent_thread_id"
        case forkedFromId
        case forkedFromIdSnake = "forked_from_id"
        case rootThreadId
        case rootThreadIdSnake = "root_thread_id"
        case agentId
        case agentIdSnake = "agent_id"
        case agentNickname
        case agentNicknameSnake = "agent_nickname"
        case agentRole
        case agentRoleSnake = "agent_role"
        case agentType
        case agentTypeSnake = "agent_type"
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        let previewValue = (try? container.decodeIfPresent(String.self, forKey: .preview)) ?? ""
        let nameValue = (try? container.decodeIfPresent(String.self, forKey: .name)) ?? ""
        preview = previewValue.isEmpty ? nameValue : previewValue
        modelProvider = (try? container.decodeIfPresent(String.self, forKey: .modelProvider))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelProviderSnake))
            ?? ""
        createdAt = (try? container.decodeIfPresent(Int64.self, forKey: .createdAt))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .createdAtSnake))
            ?? 0
        updatedAt = (try? container.decodeIfPresent(Int64.self, forKey: .updatedAt))
            ?? (try? container.decodeIfPresent(Int64.self, forKey: .updatedAtSnake))
            ?? 0
        cwd = (try? container.decodeIfPresent(String.self, forKey: .cwd)) ?? ""
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        cliVersion = (try? container.decodeIfPresent(String.self, forKey: .cliVersion))
            ?? (try? container.decodeIfPresent(String.self, forKey: .cliVersionSnake))
            ?? ""
        let parentFromPrimary = try? container.decodeIfPresent(String.self, forKey: .parentThreadId)
        let parentFromSnake = try? container.decodeIfPresent(String.self, forKey: .parentThreadIdSnake)
        let parentFromForkCamel = try? container.decodeIfPresent(String.self, forKey: .forkedFromId)
        let parentFromForkSnake = try? container.decodeIfPresent(String.self, forKey: .forkedFromIdSnake)
        parentThreadId = parentFromPrimary ?? parentFromSnake ?? parentFromForkCamel ?? parentFromForkSnake

        let rootFromPrimary = try? container.decodeIfPresent(String.self, forKey: .rootThreadId)
        let rootFromSnake = try? container.decodeIfPresent(String.self, forKey: .rootThreadIdSnake)
        rootThreadId = rootFromPrimary ?? rootFromSnake

        let sourceAny = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
        let directAgentIdPrimary = try? container.decodeIfPresent(String.self, forKey: .agentId)
        let directAgentIdSnake = try? container.decodeIfPresent(String.self, forKey: .agentIdSnake)
        let directAgentId = directAgentIdPrimary ?? directAgentIdSnake
        let directNicknamePrimary = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
        let directNicknameSnake = try? container.decodeIfPresent(String.self, forKey: .agentNicknameSnake)
        let directNickname = directNicknamePrimary ?? directNicknameSnake

        let directRolePrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
        let directRoleSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
        let directRoleType = try? container.decodeIfPresent(String.self, forKey: .agentType)
        let directRoleTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
        let directRole = directRolePrimary ?? directRoleSnake ?? directRoleType ?? directRoleTypeSnake

        agentId = Self.sanitized(directAgentId)
            ?? Self.sanitized(Self.extractThreadSpawnField(sourceAny?.value, keys: ["agent_id", "agentId"]))
        agentNickname = Self.sanitized(directNickname)
            ?? Self.sanitized(Self.extractThreadSpawnField(sourceAny?.value, keys: ["agent_nickname", "agentNickname"]))
        agentRole = Self.sanitized(directRole)
            ?? Self.sanitized(Self.extractThreadSpawnField(sourceAny?.value, keys: ["agent_role", "agentRole", "agent_type", "agentType"]))
    }

    fileprivate static func sanitized(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    fileprivate static func extractThreadSpawnField(_ source: Any?, keys: [String]) -> String? {
        guard let sourceDict = source as? [String: Any] else { return nil }
        let subAgent = (sourceDict["subAgent"] as? [String: Any]) ?? (sourceDict["sub_agent"] as? [String: Any])
        guard let subAgent else { return nil }
        let threadSpawn = (subAgent["thread_spawn"] as? [String: Any]) ?? (subAgent["threadSpawn"] as? [String: Any])
        let containers: [[String: Any]] = [threadSpawn, subAgent].compactMap { $0 }
        guard !containers.isEmpty else { return nil }
        for dict in containers {
            for key in keys {
                if let value = dict[key] as? String {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                } else if let value = dict[key] as? NSNumber {
                    return value.stringValue
                }
            }
        }
        return nil
    }
}

// MARK: - Thread Resume

struct ThreadResumeParams: Encodable {
    let threadId: String
    var cwd: String?
    var approvalPolicy: String?
    var sandbox: String?
    let persistExtendedHistory: Bool? = true
}

struct ThreadResumeResponse: Decodable {
    let thread: ResumedThread
    let model: String
    let modelProvider: String?
    let cwd: String
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case thread
        case model
        case modelProvider
        case modelProviderSnake = "model_provider"
        case cwd
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(ResumedThread.self, forKey: .thread)
        model = try container.decode(String.self, forKey: .model)
        modelProvider = (try? container.decodeIfPresent(String.self, forKey: .modelProvider))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelProviderSnake))
        cwd = try container.decode(String.self, forKey: .cwd)
        reasoningEffort = (try? container.decodeIfPresent(String.self, forKey: .reasoningEffort))
            ?? (try? container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake))
    }
}

// MARK: - Thread Read

struct ThreadReadParams: Encodable {
    let threadId: String
    var includeTurns: Bool? = true
}

struct ThreadReadResponse: Decodable {
    let thread: ResumedThread
    let model: String?
    let modelProvider: String?
    let cwd: String?
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case thread
        case model
        case modelProvider
        case modelProviderSnake = "model_provider"
        case cwd
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(ResumedThread.self, forKey: .thread)
        model = try? container.decodeIfPresent(String.self, forKey: .model)
        modelProvider = (try? container.decodeIfPresent(String.self, forKey: .modelProvider))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelProviderSnake))
        cwd = try? container.decodeIfPresent(String.self, forKey: .cwd)
        reasoningEffort = (try? container.decodeIfPresent(String.self, forKey: .reasoningEffort))
            ?? (try? container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake))
    }
}

struct ThreadForkParams: Encodable {
    let threadId: String
    var cwd: String?
    var approvalPolicy: String?
    var sandbox: String?
    let persistExtendedHistory: Bool? = true
}

struct ThreadForkResponse: Decodable {
    let thread: ResumedThread
    let model: String
    let modelProvider: String?
    let cwd: String
    let reasoningEffort: String?

    private enum CodingKeys: String, CodingKey {
        case thread
        case model
        case modelProvider
        case modelProviderSnake = "model_provider"
        case cwd
        case reasoningEffort
        case reasoningEffortSnake = "reasoning_effort"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        thread = try container.decode(ResumedThread.self, forKey: .thread)
        model = try container.decode(String.self, forKey: .model)
        modelProvider = (try? container.decodeIfPresent(String.self, forKey: .modelProvider))
            ?? (try? container.decodeIfPresent(String.self, forKey: .modelProviderSnake))
        cwd = try container.decode(String.self, forKey: .cwd)
        reasoningEffort = (try? container.decodeIfPresent(String.self, forKey: .reasoningEffort))
            ?? (try? container.decodeIfPresent(String.self, forKey: .reasoningEffortSnake))
    }
}

struct ThreadRollbackParams: Encodable {
    let threadId: String
    let numTurns: Int
}

struct ThreadRollbackResponse: Decodable {
    let thread: ResumedThread
}

struct ThreadSetNameParams: Encodable {
    let threadId: String
    let name: String
}

struct ThreadSetNameResponse: Decodable {}

struct ThreadArchiveParams: Encodable {
    let threadId: String
}

struct ThreadArchiveResponse: Decodable {}

struct ResumedThread: Decodable {
    let id: String
    let path: String?
    let turns: [ResumedTurn]
    let parentThreadId: String?
    let rootThreadId: String?
    let agentId: String?
    let agentNickname: String?
    let agentRole: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case turns
        case items
        case parentThreadId
        case parentThreadIdSnake = "parent_thread_id"
        case forkedFromId
        case forkedFromIdSnake = "forked_from_id"
        case rootThreadId
        case rootThreadIdSnake = "root_thread_id"
        case agentId
        case agentIdSnake = "agent_id"
        case agentNickname
        case agentNicknameSnake = "agent_nickname"
        case agentRole
        case agentRoleSnake = "agent_role"
        case agentType
        case agentTypeSnake = "agent_type"
        case source
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        path = try? container.decodeIfPresent(String.self, forKey: .path)
        let parentFromPrimary = try? container.decodeIfPresent(String.self, forKey: .parentThreadId)
        let parentFromSnake = try? container.decodeIfPresent(String.self, forKey: .parentThreadIdSnake)
        let parentFromForkCamel = try? container.decodeIfPresent(String.self, forKey: .forkedFromId)
        let parentFromForkSnake = try? container.decodeIfPresent(String.self, forKey: .forkedFromIdSnake)
        parentThreadId = parentFromPrimary ?? parentFromSnake ?? parentFromForkCamel ?? parentFromForkSnake

        let rootFromPrimary = try? container.decodeIfPresent(String.self, forKey: .rootThreadId)
        let rootFromSnake = try? container.decodeIfPresent(String.self, forKey: .rootThreadIdSnake)
        rootThreadId = rootFromPrimary ?? rootFromSnake

        let sourceAny = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
        let directAgentIdPrimary = try? container.decodeIfPresent(String.self, forKey: .agentId)
        let directAgentIdSnake = try? container.decodeIfPresent(String.self, forKey: .agentIdSnake)
        let directAgentId = directAgentIdPrimary ?? directAgentIdSnake
        let directNicknamePrimary = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
        let directNicknameSnake = try? container.decodeIfPresent(String.self, forKey: .agentNicknameSnake)
        let directNickname = directNicknamePrimary ?? directNicknameSnake

        let directRolePrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
        let directRoleSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
        let directRoleType = try? container.decodeIfPresent(String.self, forKey: .agentType)
        let directRoleTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
        let directRole = directRolePrimary ?? directRoleSnake ?? directRoleType ?? directRoleTypeSnake

        agentId = ThreadSummary.sanitized(directAgentId)
            ?? ThreadSummary.sanitized(ThreadSummary.extractThreadSpawnField(sourceAny?.value, keys: ["agent_id", "agentId"]))
        agentNickname = ThreadSummary.sanitized(directNickname)
            ?? ThreadSummary.sanitized(ThreadSummary.extractThreadSpawnField(sourceAny?.value, keys: ["agent_nickname", "agentNickname"]))
        agentRole = ThreadSummary.sanitized(directRole)
            ?? ThreadSummary.sanitized(ThreadSummary.extractThreadSpawnField(sourceAny?.value, keys: ["agent_role", "agentRole", "agent_type", "agentType"]))
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
    let status: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case items
        case status
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        items = (try? container.decodeIfPresent([ResumedThreadItem].self, forKey: .items)) ?? []
        status = try? container.decodeIfPresent(String.self, forKey: .status)
    }

    init(id: String, items: [ResumedThreadItem]) {
        self.id = id
        self.items = items
        self.status = nil
    }
}

enum ResumedThreadItem: Decodable {
    case userMessage([ResumedUserInput])
    case agentMessage(text: String, phase: String?, agentId: String?, agentNickname: String?, agentRole: String?)
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
        receiverAgents: [ResumedCollabAgentRef],
        prompt: String?
    )
    case webSearch(query: String, action: AnyCodable?)
    case imageView(path: String)
    case enteredReviewMode(review: String)
    case exitedReviewMode(review: String)
    case dynamicToolCall(
        tool: String,
        arguments: AnyCodable?,
        status: String,
        contentItems: AnyCodable?,
        durationMs: Int?
    )
    case contextCompaction
    case unknown(type: String)
    case ignored

    private enum CodingKeys: String, CodingKey {
        case type
        case id
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
        case receiverThreadIdsSnake = "receiver_thread_ids"
        case receiverAgents
        case receiverAgentsSnake = "receiver_agents"
        case prompt
        case query
        case action
        case path
        case review
        case source
        case arguments
        case contentItems
        case agentId
        case agentIdSnake = "agent_id"
        case agentNickname
        case agentNicknameSnake = "agent_nickname"
        case nickname
        case name
        case agentRole
        case agentRoleSnake = "agent_role"
        case agentType
        case agentTypeSnake = "agent_type"
        case role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawType = (try? container.decode(String.self, forKey: .type)) ?? ""
        let type = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
        switch type {
        case "userMessage":
            var content = (try? container.decodeIfPresent([ResumedUserInput].self, forKey: .content)) ?? []
            if content.isEmpty, let text = Self.decodeString(container, forKey: .text), !text.isEmpty {
                content = [ResumedUserInput(type: "text", text: text)]
            }
            self = .userMessage(content)
        case "agentMessage", "assistantMessage":
            let sourceAny = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
            let directAgentId = Self.decodeString(container, forKey: .agentId)
                ?? Self.decodeString(container, forKey: .agentIdSnake)
                ?? Self.decodeString(container, forKey: .id)
            let directNickname = Self.decodeString(container, forKey: .agentNickname)
                ?? Self.decodeString(container, forKey: .agentNicknameSnake)
                ?? Self.decodeString(container, forKey: .nickname)
                ?? Self.decodeString(container, forKey: .name)
            let directRole = Self.decodeString(container, forKey: .agentRole)
                ?? Self.decodeString(container, forKey: .agentRoleSnake)
                ?? Self.decodeString(container, forKey: .agentType)
                ?? Self.decodeString(container, forKey: .agentTypeSnake)
                ?? Self.decodeString(container, forKey: .role)
            self = .agentMessage(
                text: Self.decodeString(container, forKey: .text) ?? "",
                phase: Self.decodeString(container, forKey: .phase),
                agentId: ThreadSummary.sanitized(directAgentId)
                    ?? ThreadSummary.sanitized(
                        ThreadSummary.extractThreadSpawnField(
                            sourceAny?.value,
                            keys: ["agent_id", "agentId", "id"]
                        )
                    ),
                agentNickname: ThreadSummary.sanitized(directNickname)
                    ?? ThreadSummary.sanitized(
                        ThreadSummary.extractThreadSpawnField(
                            sourceAny?.value,
                            keys: ["agent_nickname", "agentNickname", "nickname", "name"]
                        )
                    ),
                agentRole: ThreadSummary.sanitized(directRole)
                    ?? ThreadSummary.sanitized(
                        ThreadSummary.extractThreadSpawnField(
                            sourceAny?.value,
                            keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]
                        )
                    )
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
                receiverThreadIds: Self.decodeStringArray(container, forKey: .receiverThreadIds)
                    + Self.decodeStringArray(container, forKey: .receiverThreadIdsSnake),
                receiverAgents: (try? container.decodeIfPresent([ResumedCollabAgentRef].self, forKey: .receiverAgents))
                    ?? (try? container.decodeIfPresent([ResumedCollabAgentRef].self, forKey: .receiverAgentsSnake))
                    ?? [],
                prompt: Self.decodeString(container, forKey: .prompt)
            )
        case "webSearch", "web_search", "web-search", "websearch":
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
        case "dynamicToolCall":
            self = .dynamicToolCall(
                tool: Self.decodeString(container, forKey: .tool) ?? "",
                arguments: try? container.decodeIfPresent(AnyCodable.self, forKey: .arguments),
                status: Self.decodeString(container, forKey: .status) ?? "unknown",
                contentItems: try? container.decodeIfPresent(AnyCodable.self, forKey: .contentItems),
                durationMs: Self.decodeInt(container, forKey: .durationMs)
            )
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

struct ResumedCollabAgentRef: Decodable {
    let threadId: String
    let agentId: String?
    let agentNickname: String?
    let agentRole: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case source
        case threadId
        case threadIdSnake = "thread_id"
        case agentId
        case agentIdSnake = "agent_id"
        case agentNickname
        case agentNicknameSnake = "agent_nickname"
        case nickname
        case name
        case agentRole
        case agentRoleSnake = "agent_role"
        case agentType
        case agentTypeSnake = "agent_type"
        case role
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sourceAny = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
        let fallbackStringId = (try? container.decodeIfPresent(String.self, forKey: .id)) ?? nil
        let fallbackIntId = (try? container.decodeIfPresent(Int.self, forKey: .id)) ?? nil
        let fallbackId = ThreadSummary.sanitized(fallbackStringId) ?? fallbackIntId.map(String.init)
        let threadIdFromSource = ThreadSummary.extractThreadSpawnField(
            sourceAny?.value,
            keys: ["thread_id", "threadId"]
        )
        threadId = ThreadSummary.sanitized((try? container.decodeIfPresent(String.self, forKey: .threadId))
            ?? (try? container.decodeIfPresent(String.self, forKey: .threadIdSnake))
            ?? threadIdFromSource
            ?? fallbackId) ?? ""
        let agentIdPrimary = try? container.decodeIfPresent(String.self, forKey: .agentId)
        let agentIdSnake = try? container.decodeIfPresent(String.self, forKey: .agentIdSnake)
        let agentIdFromSource = ThreadSummary.extractThreadSpawnField(
            sourceAny?.value,
            keys: ["agent_id", "agentId", "id"]
        )
        let agentIdValue = agentIdPrimary ?? agentIdSnake ?? agentIdFromSource ?? fallbackId
        let nicknamePrimary = try? container.decodeIfPresent(String.self, forKey: .agentNickname)
        let nicknameSnake = try? container.decodeIfPresent(String.self, forKey: .agentNicknameSnake)
        let nicknameGeneric = try? container.decodeIfPresent(String.self, forKey: .nickname)
        let nameGeneric = try? container.decodeIfPresent(String.self, forKey: .name)
        let nicknameFromSource = ThreadSummary.extractThreadSpawnField(
            sourceAny?.value,
            keys: ["agent_nickname", "agentNickname", "nickname", "name"]
        )
        let nickname = nicknamePrimary ?? nicknameSnake ?? nicknameGeneric ?? nameGeneric ?? nicknameFromSource

        let rolePrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
        let roleSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
        let roleType = try? container.decodeIfPresent(String.self, forKey: .agentType)
        let roleTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
        let roleGeneric = try? container.decodeIfPresent(String.self, forKey: .role)
        let roleFromSource = ThreadSummary.extractThreadSpawnField(
            sourceAny?.value,
            keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]
        )
        let role = rolePrimary ?? roleSnake ?? roleType ?? roleTypeSnake ?? roleGeneric ?? roleFromSource
        agentId = ThreadSummary.sanitized(agentIdValue)
        agentNickname = ThreadSummary.sanitized(nickname)
        agentRole = ThreadSummary.sanitized(role)
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
        case unifiedDiff = "unified_diff"
    }

    private struct FileChangeKindObject: Decodable {
        let type: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = (try? container.decodeIfPresent(String.self, forKey: .path)) ?? "unknown"
        if let kindString = try? container.decode(String.self, forKey: .kind) {
            kind = kindString
        } else if let kindObject = try? container.decode(FileChangeKindObject.self, forKey: .kind) {
            kind = kindObject.type ?? "update"
        } else {
            kind = "update"
        }
        diff = (try? container.decodeIfPresent(String.self, forKey: .diff))
            ?? (try? container.decodeIfPresent(String.self, forKey: .unifiedDiff))
            ?? ""
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

// MARK: - Config

struct ConfigReadParams: Encodable {
    let includeLayers: Bool
    var cwd: String?
}

struct ConfigReadResponse: Decodable {
    let config: AnyCodable
}

struct ConfigValueWriteParams<Value: Encodable>: Encodable {
    let keyPath: String
    let value: Value
    let mergeStrategy: String
    var filePath: String?
    var expectedVersion: String?
}

struct ConfigWriteResponse: Decodable {
    let status: String
    let version: String
    let filePath: String
}

// MARK: - Experimental Features

struct ExperimentalFeatureListParams: Encodable {
    var cursor: String?
    var limit: Int?
}

struct ExperimentalFeatureListResponse: Decodable {
    let data: [ExperimentalFeature]
    let nextCursor: String?
}

struct ExperimentalFeature: Decodable, Identifiable {
    let name: String
    let stage: String
    let displayName: String?
    let description: String?
    let announcement: String?
    let enabled: Bool
    let defaultEnabled: Bool

    var id: String { name }
}

// MARK: - Skills

struct SkillsListParams: Encodable {
    var cwds: [String]?
    var forceReload: Bool?
}

struct SkillsListResponse: Decodable {
    let data: [SkillsListEntry]
}

struct SkillsListEntry: Decodable {
    let cwd: String
    let skills: [SkillMetadata]
}

struct SkillMetadata: Decodable, Identifiable {
    let name: String
    let description: String
    let path: String
    let scope: String
    let enabled: Bool

    var id: String { "\(path)#\(name)" }
}

// MARK: - Fuzzy File Search

struct FuzzyFileSearchParams: Encodable {
    let query: String
    let roots: [String]
    var cancellationToken: String?
}

struct FuzzyFileSearchResponse: Decodable {
    let files: [FuzzyFileSearchResult]
}

struct FuzzyFileSearchResult: Decodable, Identifiable {
    let root: String
    let path: String
    let fileName: String
    let score: Int
    let indices: [Int]?

    private enum CodingKeys: String, CodingKey {
        case root
        case path
        case fileName = "file_name"
        case score
        case indices
    }

    var id: String { path }
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

struct GetAuthStatusParams: Encodable {
    let includeToken: Bool
    let refreshToken: Bool
}

struct GetAuthStatusResponse: Decodable {
    let authMethod: String?
    let authToken: String?
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

// MARK: - Rate Limits

struct RateLimitWindow: Decodable {
    let usedPercent: Double
    let windowDurationMins: Int?
    let resetsAt: Double?
}

struct CreditsSnapshot: Decodable {
    let hasCredits: Bool
    let unlimited: Bool
    let balance: String?
}

struct RateLimitSnapshot: Decodable {
    let limitId: String?
    let limitName: String?
    let primary: RateLimitWindow?
    let secondary: RateLimitWindow?
    let credits: CreditsSnapshot?
    let planType: String?
}

struct GetAccountRateLimitsResponse: Decodable {
    let rateLimits: RateLimitSnapshot
    let rateLimitsByLimitId: [String: RateLimitSnapshot]?
}

struct AccountRateLimitsUpdatedNotification: Decodable {
    let rateLimits: RateLimitSnapshot
}
