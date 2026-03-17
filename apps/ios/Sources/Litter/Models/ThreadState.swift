import Foundation
import Observation

struct ThreadKey: Hashable, Sendable {
    let serverId: String
    let threadId: String
}

@MainActor
@Observable
final class ThreadState: Identifiable {
    nonisolated let id: ThreadKey
    nonisolated var key: ThreadKey { id }
    let serverId: String
    let threadId: String
    var serverName: String
    var serverSource: ServerSource

    var items: [ ConversationItem] = []
    var status: ConversationStatus = .ready
    var preview: String = ""
    var cwd: String = ""
    var model: String = ""
    var modelProvider: String = ""
    var reasoningEffort: String?
    var modelContextWindow: Int64?
    var contextTokensUsed: Int64?
    var rolloutPath: String?
    var parentThreadId: String?
    var rootThreadId: String?
    var agentNickname: String?
    var agentRole: String?
    var updatedAt: Date = Date()
    var requiresOpenHydration: Bool = true
    var activeTurnId: String?

    var agentStatus: SubagentStatus = .unknown

    var hasTurnActive: Bool {
        if case .thinking = status { return true }
        return false
    }

    var isSubagent: Bool {
        parentThreadId?.isEmpty == false && agentDisplayLabel != nil
    }

    var isFork: Bool {
        parentThreadId?.isEmpty == false
    }

    var agentDisplayLabel: String? {
        let nickname = agentNickname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let role = agentRole?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !nickname.isEmpty && !role.isEmpty {
            return "\(nickname) [\(role)]"
        }
        if !nickname.isEmpty {
            return nickname
        }
        if !role.isEmpty {
            return "[\(role)]"
        }
        return nil
    }

    init(serverId: String, threadId: String, serverName: String, serverSource: ServerSource) {
        self.id = ThreadKey(serverId: serverId, threadId: threadId)
        self.serverId = serverId
        self.threadId = threadId
        self.serverName = serverName
        self.serverSource = serverSource
    }
}

enum SubagentStatus: String {
    case unknown
    case pendingInit
    case running
    case interrupted
    case completed
    case errored
    case shutdown

    init(fromRaw raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Try exact camelCase match first (server sends these)
        switch trimmed {
        case "pendingInit", "PendingInit":
            self = .pendingInit
        case "running", "Running":
            self = .running
        case "interrupted", "Interrupted":
            self = .interrupted
        case "completed", "Completed":
            self = .completed
        case "errored", "Errored":
            self = .errored
        case "shutdown", "Shutdown":
            self = .shutdown
        case "notFound", "NotFound":
            self = .unknown
        default:
            // Fuzzy fallback
            let normalized = trimmed.lowercased().replacingOccurrences(of: "_", with: "")
            switch normalized {
            case "pendinginit", "pending":
                self = .pendingInit
            case "running", "inprogress", "active", "thinking":
                self = .running
            case "interrupted":
                self = .interrupted
            case "completed", "complete", "done", "idle":
                self = .completed
            case "errored", "error", "failed":
                self = .errored
            case "shutdown":
                self = .shutdown
            default:
                self = .unknown
            }
        }
    }
}

struct SavedServer: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let sshPort: UInt16?
    let source: String
    let hasCodexServer: Bool
    let wakeMAC: String?
    let sshPortForwardingEnabled: Bool?
    let websocketURL: String?

    func toDiscoveredServer() -> DiscoveredServer {
        let codexPort = hasCodexServer ? port : nil
        let resolvedSSHPort = sshPort ?? (hasCodexServer ? nil : port)
        return DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: codexPort,
            sshPort: resolvedSSHPort,
            source: ServerSource.from(source),
            hasCodexServer: hasCodexServer,
            wakeMAC: wakeMAC,
            sshPortForwardingEnabled: sshPortForwardingEnabled ?? false,
            websocketURL: websocketURL
        )
    }

    static func from(_ server: DiscoveredServer) -> SavedServer {
        SavedServer(
            id: server.id,
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            sshPort: server.sshPort,
            source: server.source.rawString,
            hasCodexServer: server.hasCodexServer,
            wakeMAC: server.wakeMAC,
            sshPortForwardingEnabled: server.sshPortForwardingEnabled,
            websocketURL: server.websocketURL
        )
    }
}
