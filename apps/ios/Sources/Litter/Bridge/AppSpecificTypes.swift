import Foundation

struct AnyEncodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void

    init<T: Encodable>(_ value: T) {
        encodeImpl = value.encode
    }

    func encode(to encoder: Encoder) throws {
        try encodeImpl(encoder)
    }
}

enum TurnSandboxPolicy: Encodable {
    case dangerFullAccess
    case readOnly
    case workspaceWrite

    init?(mode: String?) {
        switch mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "danger-full-access":
            self = .dangerFullAccess
        case "read-only":
            self = .readOnly
        case "workspace-write":
            self = .workspaceWrite
        default:
            return nil
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .dangerFullAccess:
            var container = encoder.container(keyedBy: DangerFullAccessCodingKeys.self)
            try container.encode("dangerFullAccess", forKey: .type)
        case .readOnly:
            var container = encoder.container(keyedBy: ReadOnlyCodingKeys.self)
            try container.encode("readOnly", forKey: .type)
            try container.encode(TurnReadOnlyAccess.fullAccess, forKey: .access)
            try container.encode(false, forKey: .networkAccess)
        case .workspaceWrite:
            var container = encoder.container(keyedBy: WorkspaceWriteCodingKeys.self)
            try container.encode("workspaceWrite", forKey: .type)
            try container.encode([String](), forKey: .writableRoots)
            try container.encode(TurnReadOnlyAccess.fullAccess, forKey: .readOnlyAccess)
            try container.encode(false, forKey: .networkAccess)
            try container.encode(false, forKey: .excludeTmpdirEnvVar)
            try container.encode(false, forKey: .excludeSlashTmp)
        }
    }

    var ffiValue: SandboxPolicy {
        switch self {
        case .dangerFullAccess:
            return .dangerFullAccess
        case .readOnly:
            return .readOnly(access: .fullAccess, networkAccess: false)
        case .workspaceWrite:
            return .workspaceWrite(
                writableRoots: [],
                readOnlyAccess: .fullAccess,
                networkAccess: false,
                excludeTmpdirEnvVar: false,
                excludeSlashTmp: false
            )
        }
    }

    private enum DangerFullAccessCodingKeys: String, CodingKey {
        case type
    }

    private enum ReadOnlyCodingKeys: String, CodingKey {
        case type
        case access
        case networkAccess
    }

    private enum WorkspaceWriteCodingKeys: String, CodingKey {
        case type
        case writableRoots
        case readOnlyAccess
        case networkAccess
        case excludeTmpdirEnvVar
        case excludeSlashTmp
    }
}

private enum TurnReadOnlyAccess: Encodable {
    case fullAccess

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("fullAccess", forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

extension ThreadRealtimeAudioChunk: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: AudioChunkEncodingKeys.self)
        try container.encode(data, forKey: .data)
        try container.encode(sampleRate, forKey: .sampleRate)
        try container.encode(numChannels, forKey: .numChannels)
        try container.encodeIfPresent(samplesPerChannel, forKey: .samplesPerChannel)
    }
}

private enum AudioChunkEncodingKeys: String, CodingKey {
    case data, sampleRate, numChannels, samplesPerChannel
}

extension SkillMetadata: Identifiable {
    public var id: String { "\(path)#\(name)" }
}

extension ExperimentalFeature: Identifiable {
    public var id: String { name }
}

extension Model: Identifiable {}

extension RateLimitSnapshot: Identifiable {
    public var id: String { limitId ?? UUID().uuidString }
}

extension AskForApproval {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "untrusted":
            self = .unlessTrusted
        case "on-failure":
            self = .onFailure
        case "on-request":
            self = .onRequest
        case "never":
            self = .never
        default:
            return nil
        }
    }
}

extension SandboxMode {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "read-only":
            self = .readOnly
        case "workspace-write":
            self = .workspaceWrite
        case "danger-full-access":
            self = .dangerFullAccess
        default:
            return nil
        }
    }
}

extension ReasoningEffort {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "none":
            self = .none
        case "minimal":
            self = .minimal
        case "low":
            self = .low
        case "medium":
            self = .medium
        case "high":
            self = .high
        case "xhigh":
            self = .xHigh
        default:
            return nil
        }
    }

    var wireValue: String {
        switch self {
        case .none: return "none"
        case .minimal: return "minimal"
        case .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xHigh: return "xhigh"
        }
    }
}

extension ServiceTier {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "fast":
            self = .fast
        case "flex":
            self = .flex
        default:
            return nil
        }
    }
}

extension MergeStrategy {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "replace":
            self = .replace
        case "upsert":
            self = .upsert
        default:
            return nil
        }
    }
}

extension JsonValue {
    static let nullValue = JsonValue(
        kind: .null,
        boolValue: nil,
        i64Value: nil,
        u64Value: nil,
        f64Value: nil,
        stringValue: nil,
        arrayItems: nil,
        objectEntries: nil
    )

    init(anyJSON value: Any) throws {
        switch value {
        case is NSNull:
            self = .nullValue
        case let value as Bool:
            self = JsonValue(
                kind: .bool,
                boolValue: value,
                i64Value: nil,
                u64Value: nil,
                f64Value: nil,
                stringValue: nil,
                arrayItems: nil,
                objectEntries: nil
            )
        case let value as String:
            self = JsonValue(
                kind: .string,
                boolValue: nil,
                i64Value: nil,
                u64Value: nil,
                f64Value: nil,
                stringValue: value,
                arrayItems: nil,
                objectEntries: nil
            )
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                self = JsonValue(
                    kind: .bool,
                    boolValue: value.boolValue,
                    i64Value: nil,
                    u64Value: nil,
                    f64Value: nil,
                    stringValue: nil,
                    arrayItems: nil,
                    objectEntries: nil
                )
            } else if let exactInt = Int64(exactly: value) {
                self = JsonValue(
                    kind: .i64,
                    boolValue: nil,
                    i64Value: exactInt,
                    u64Value: nil,
                    f64Value: nil,
                    stringValue: nil,
                    arrayItems: nil,
                    objectEntries: nil
                )
            } else if let exactUInt = UInt64(exactly: value) {
                self = JsonValue(
                    kind: .u64,
                    boolValue: nil,
                    i64Value: nil,
                    u64Value: exactUInt,
                    f64Value: nil,
                    stringValue: nil,
                    arrayItems: nil,
                    objectEntries: nil
                )
            } else {
                self = JsonValue(
                    kind: .f64,
                    boolValue: nil,
                    i64Value: nil,
                    u64Value: nil,
                    f64Value: value.doubleValue,
                    stringValue: nil,
                    arrayItems: nil,
                    objectEntries: nil
                )
            }
        case let values as [Any]:
            self = JsonValue(
                kind: .array,
                boolValue: nil,
                i64Value: nil,
                u64Value: nil,
                f64Value: nil,
                stringValue: nil,
                arrayItems: try values.map(JsonValue.init(anyJSON:)),
                objectEntries: nil
            )
        case let values as [String: Any]:
            self = JsonValue(
                kind: .object,
                boolValue: nil,
                i64Value: nil,
                u64Value: nil,
                f64Value: nil,
                stringValue: nil,
                arrayItems: nil,
                objectEntries: try values
                    .sorted { $0.key < $1.key }
                    .map { key, value in
                        JsonObjectEntry(key: key, value: try JsonValue(anyJSON: value))
                    }
            )
        default:
            throw NSError(
                domain: "Litter.JsonValue",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Unsupported JSON value: \(type(of: value))"]
            )
        }
    }

    init<T: Encodable>(encodable value: T) throws {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        try self.init(anyJSON: object)
    }

    var foundationValue: Any {
        switch kind {
        case .null:
            return NSNull()
        case .bool:
            return boolValue ?? false
        case .i64:
            return i64Value ?? 0
        case .u64:
            return u64Value ?? 0
        case .f64:
            return f64Value ?? 0
        case .string:
            return stringValue ?? ""
        case .array:
            return (arrayItems ?? []).map(\.foundationValue)
        case .object:
            return Dictionary(uniqueKeysWithValues: (objectEntries ?? []).map { ($0.key, $0.value.foundationValue) })
        }
    }

    var objectValue: [String: Any]? {
        foundationValue as? [String: Any]
    }

    func value(at keyPath: [String]) -> JsonValue? {
        guard let first = keyPath.first else { return self }
        guard kind == .object,
              let next = objectEntries?.first(where: { $0.key == first })?.value else {
            return nil
        }
        return next.value(at: Array(keyPath.dropFirst()))
    }

    var stringScalar: String? {
        guard kind == .string else { return nil }
        return stringValue
    }
}

extension AbsolutePath: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

extension JsonValue: Encodable {
    public func encode(to encoder: Encoder) throws {
        switch kind {
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .bool:
            var container = encoder.singleValueContainer()
            try container.encode(boolValue ?? false)
        case .i64:
            var container = encoder.singleValueContainer()
            try container.encode(i64Value ?? 0)
        case .u64:
            var container = encoder.singleValueContainer()
            try container.encode(u64Value ?? 0)
        case .f64:
            var container = encoder.singleValueContainer()
            try container.encode(f64Value ?? 0)
        case .string:
            var container = encoder.singleValueContainer()
            try container.encode(stringValue ?? "")
        case .array:
            var container = encoder.unkeyedContainer()
            for item in arrayItems ?? [] {
                try container.encode(item)
            }
        case .object:
            var container = encoder.container(keyedBy: JSONCodingKey.self)
            for entry in objectEntries ?? [] {
                try entry.value.encode(to: container.superEncoder(forKey: JSONCodingKey(entry.key)))
            }
        }
    }
}

private struct JSONCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?

    init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    init?(stringValue: String) {
        self.init(stringValue)
    }

    init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}

extension PlanType {
    init?(wireValue: String?) {
        switch wireValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "free":
            self = .free
        case "go":
            self = .go
        case "plus":
            self = .plus
        case "pro":
            self = .pro
        case "team":
            self = .team
        case "business":
            self = .business
        case "enterprise":
            self = .enterprise
        case "edu":
            self = .edu
        case "unknown":
            self = .unknown
        default:
            return nil
        }
    }

    var wireValue: String {
        switch self {
        case .free: return "free"
        case .go: return "go"
        case .plus: return "plus"
        case .pro: return "pro"
        case .team: return "team"
        case .business: return "business"
        case .enterprise: return "enterprise"
        case .edu: return "edu"
        case .unknown: return "unknown"
        }
    }
}

extension ReasoningEffortOption: Identifiable {
    public var id: String { reasoningEffort.wireValue }
}

extension UserInput: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: UserInputCodingKeys.self)
        switch self {
        case .text(let text, _):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let url):
            try container.encode("image", forKey: .type)
            try container.encode(url, forKey: .url)
        case .localImage(let path):
            try container.encode("localImage", forKey: .type)
            try container.encode(path, forKey: .path)
        case .skill(let name, let path):
            try container.encode("skill", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        case .mention(let name, let path):
            try container.encode("mention", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(path, forKey: .path)
        }
    }
}

private enum UserInputCodingKeys: String, CodingKey {
    case type, text, url, path, name
}

extension ReviewTarget: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ReviewTargetCodingKeys.self)
        switch self {
        case .uncommittedChanges:
            try container.encode("uncommittedChanges", forKey: .type)
        case .baseBranch(let branch):
            try container.encode("baseBranch", forKey: .type)
            try container.encode(branch, forKey: .branch)
        case .commit(let sha, let title):
            try container.encode("commit", forKey: .type)
            try container.encode(sha, forKey: .sha)
            try container.encodeIfPresent(title, forKey: .title)
        case .custom(let instructions):
            try container.encode("custom", forKey: .type)
            try container.encode(instructions, forKey: .instructions)
        }
    }
}

private enum ReviewTargetCodingKeys: String, CodingKey {
    case type, branch, sha, title, instructions
}

extension ConfigEdit: Encodable {
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: ConfigEditCodingKeys.self)
        try container.encode(keyPath, forKey: .keyPath)
        try container.encode(value, forKey: .value)
        switch mergeStrategy {
        case .replace:
            try container.encode("replace", forKey: .mergeStrategy)
        case .upsert:
            try container.encode("upsert", forKey: .mergeStrategy)
        }
    }
}

private enum ConfigEditCodingKeys: String, CodingKey {
    case keyPath, value, mergeStrategy
}
