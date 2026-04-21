import Foundation
import SwiftUI

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

struct HomeDashboardServer: Identifiable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let backendKind: SavedServerBackendKind
    let backendLabel: String
    let isLocal: Bool
    let hasIpc: Bool
    let health: AppServerHealth
    let sourceLabel: String
    let subtitle: String
    let lastUsedDirectoryHint: String?
    let defaultModelLabel: String?
    let modelCatalogCountLabel: String
    let knownDirectories: [String]
    let canBrowseDirectories: Bool
    let statusLabel: String
    let statusColor: Color

    var deduplicationKey: String {
        id
    }

    static func == (lhs: HomeDashboardServer, rhs: HomeDashboardServer) -> Bool {
        lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.host == rhs.host &&
            lhs.port == rhs.port &&
            lhs.backendKind == rhs.backendKind &&
            lhs.backendLabel == rhs.backendLabel &&
            lhs.isLocal == rhs.isLocal &&
            lhs.hasIpc == rhs.hasIpc &&
            lhs.health == rhs.health &&
            lhs.sourceLabel == rhs.sourceLabel &&
            lhs.subtitle == rhs.subtitle &&
            lhs.lastUsedDirectoryHint == rhs.lastUsedDirectoryHint &&
            lhs.defaultModelLabel == rhs.defaultModelLabel &&
            lhs.modelCatalogCountLabel == rhs.modelCatalogCountLabel &&
            lhs.knownDirectories == rhs.knownDirectories &&
            lhs.canBrowseDirectories == rhs.canBrowseDirectories &&
            lhs.statusLabel == rhs.statusLabel
    }
}

@MainActor
enum HomeDashboardSupport {
    static func recentConnectedSessions(
        from sessions: [AppSessionSummary],
        serversById: [String: HomeDashboardServer],
        limit: Int = 10
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
        return servers
            .filter { $0.health != .disconnected || $0.connectionProgress != nil }
            .map { server in
                let savedServer = SavedServerStore.server(id: server.serverId)
                let backendKind = savedServer?.backendKind ?? .codex
                let knownDirectories = savedServer?.openCodeKnownDirectories ?? []
                let defaultModelLabel = server.availableModels?
                    .first(where: \.isDefault)
                    .flatMap { model -> String? in
                        let trimmed = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                        return trimmed.isEmpty ? nil : trimmed
                    }
                return HomeDashboardServer(
                    id: server.serverId,
                    displayName: server.displayName,
                    host: server.host,
                    port: server.port,
                    backendKind: backendKind,
                    backendLabel: backendKind == .openCode ? "OpenCode" : "Codex",
                    isLocal: server.isLocal,
                    hasIpc: server.hasIpc,
                    health: server.health,
                    sourceLabel: server.connectionModeLabel,
                    subtitle: serverSubtitle(
                        savedServer: savedServer,
                        backendKind: backendKind,
                        host: server.host,
                        port: server.port,
                        isLocal: server.isLocal,
                        sourceLabel: server.connectionModeLabel
                    ),
                    lastUsedDirectoryHint: RecentDirectoryStore.shared
                        .recentDirectories(for: server.serverId, limit: 1)
                        .first?
                        .path,
                    defaultModelLabel: defaultModelLabel,
                    modelCatalogCountLabel: server.availableModels.map { "\($0.count) models" } ?? "Not loaded",
                    knownDirectories: knownDirectories,
                    canBrowseDirectories: server.canBrowseDirectories,
                    statusLabel: server.statusLabel,
                    statusColor: server.statusColor
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

                if lhs.backendLabel != rhs.backendLabel {
                    return lhs.backendLabel < rhs.backendLabel
                }

                return lhs.id < rhs.id
            }
    }

    static func serverSubtitle(for server: HomeDashboardServer) -> String {
        server.subtitle
    }

    static func workspaceLabel(for cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    private static func sessionTitle(for session: AppSessionSummary) -> String {
        session.displayTitle
    }

    private static func serverSubtitle(
        savedServer: SavedServer?,
        backendKind: SavedServerBackendKind,
        host: String,
        port: UInt16,
        isLocal: Bool,
        sourceLabel: String
    ) -> String {
        if backendKind == .openCode {
            var parts = [savedServer?.openCodeBaseURL ?? "\(host):\(port)", "OpenCode"]
            if let directory = savedServer?.openCodeKnownDirectories.first, !directory.isEmpty {
                parts.append(directory)
                if let count = savedServer?.openCodeKnownDirectories.count, count > 1 {
                    parts.append("+\(count - 1) more")
                }
            }
            return parts.joined(separator: " • ")
        }

        if isLocal {
            return "In-process server"
        }

        return "\(host):\(port) • \(sourceLabel)"
    }
}
