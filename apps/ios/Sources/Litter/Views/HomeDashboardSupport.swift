import Foundation

struct HomeDashboardRecentSession: Identifiable, Hashable {
    let key: ThreadKey
    let serverId: String
    let serverDisplayName: String
    let sessionTitle: String
    let cwd: String
    let updatedAt: Date
    let hasTurnActive: Bool

    var id: ThreadKey { key }
}

struct HomeDashboardServer: Identifiable, Hashable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let isLocal: Bool
    let health: AppServerHealth
    let sourceLabel: String

    var deduplicationKey: String {
        if isLocal {
            return "local"
        }

        let normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")
            .lowercased()

        return normalized.isEmpty ? id : normalized
    }
}

@MainActor
enum HomeDashboardSupport {
    static func recentConnectedSessions(
        from sessions: [AppSessionSummary],
        serversById: [String: HomeDashboardServer],
        limit: Int = 3
    ) -> [HomeDashboardRecentSession] {
        Array(
            sessions
                .filter { serversById[$0.key.serverId] != nil }
                .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
                .compactMap { session in
                    guard let server = serversById[session.key.serverId] else { return nil }
                    return HomeDashboardRecentSession(
                        key: session.key,
                        serverId: session.key.serverId,
                        serverDisplayName: server.displayName,
                        sessionTitle: sessionTitle(for: session),
                        cwd: session.cwd,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(session.updatedAt ?? 0)),
                        hasTurnActive: session.hasActiveTurn
                    )
                }
                .prefix(limit)
        )
    }

    static func sortedConnectedServers(
        from servers: [AppServerSnapshot],
        activeServerId: String?
    ) -> [HomeDashboardServer] {
        var seenServerKeys: Set<String> = []

        return servers
            .filter { $0.health == .connected }
            .map { server in
                HomeDashboardServer(
                    id: server.serverId,
                    displayName: server.displayName,
                    host: server.host,
                    port: server.port,
                    isLocal: server.isLocal,
                    health: server.health,
                    sourceLabel: server.isLocal ? "local" : "remote"
                )
            }
            .sorted { lhs, rhs in
                let lhsIsActive = lhs.id == activeServerId
                let rhsIsActive = rhs.id == activeServerId
                if lhsIsActive != rhsIsActive {
                    return lhsIsActive && !rhsIsActive
                }

                let byName = lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                if byName != .orderedSame {
                    return byName == .orderedAscending
                }

                return lhs.id < rhs.id
            }
            .filter { server in
                seenServerKeys.insert(server.deduplicationKey).inserted
            }
    }

    static func serverSubtitle(for server: HomeDashboardServer) -> String {
        if server.isLocal {
            return "In-process server"
        }

        return "\(server.host):\(server.port) | \(server.sourceLabel)"
    }

    static func workspaceLabel(for cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    private static func sessionTitle(for session: AppSessionSummary) -> String {
        let trimmedPreview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreview.isEmpty {
            return trimmedPreview
        }

        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }

        return "Untitled session"
    }
}
