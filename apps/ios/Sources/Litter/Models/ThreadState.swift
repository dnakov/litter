import Foundation

struct ThreadKey: Hashable, Sendable {
    let serverId: String
    let threadId: String
}

@MainActor
final class ThreadState: ObservableObject, Identifiable {
    nonisolated let id: ThreadKey
    nonisolated var key: ThreadKey { id }
    let serverId: String
    let threadId: String
    var serverName: String
    var serverSource: ServerSource

    @Published var messages: [ChatMessage] = []
    @Published var status: ConversationStatus = .ready
    @Published var preview: String = ""
    @Published var cwd: String = ""
    @Published var modelProvider: String = ""
    @Published var parentThreadId: String?
    @Published var rootThreadId: String?
    @Published var updatedAt: Date = Date()

    var hasTurnActive: Bool {
        if case .thinking = status { return true }
        return false
    }

    var isFork: Bool {
        parentThreadId?.isEmpty == false
    }

    init(serverId: String, threadId: String, serverName: String, serverSource: ServerSource) {
        self.id = ThreadKey(serverId: serverId, threadId: threadId)
        self.serverId = serverId
        self.threadId = threadId
        self.serverName = serverName
        self.serverSource = serverSource
    }
}

struct SavedServer: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let source: String
    let hasCodexServer: Bool

    func toDiscoveredServer() -> DiscoveredServer {
        DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            source: ServerSource.from(source),
            hasCodexServer: hasCodexServer
        )
    }

    static func from(_ server: DiscoveredServer) -> SavedServer {
        SavedServer(
            id: server.id,
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            source: server.source.rawString,
            hasCodexServer: server.hasCodexServer
        )
    }
}
