import Foundation
import SwiftUI

struct HomeDashboardRecentSession: Identifiable, Hashable {
    let key: ThreadKey
    let serverId: String
    let serverDisplayName: String
    let isLocal: Bool
    let sessionTitle: String
    let preview: String
    let cwd: String
    let model: String
    let agentLabel: String?
    let updatedAt: Date
    let hasTurnActive: Bool
    let isSubagent: Bool
    let isFork: Bool
    let lastResponsePreview: String?
    /// `source_turn_id` of the assistant item behind
    /// `lastResponsePreview`. Used as the crossfade key in
    /// `HomeDashboardView.responsePreview` so the text only re-animates when
    /// a new assistant reply arrives, not when the user submits a new
    /// prompt (which bumps `stats.turnCount` before any assistant text
    /// exists).
    let lastResponseTurnId: String?
    let lastUserMessage: String?
    let lastToolLabel: String?
    let stats: AppConversationStats?
    let tokenUsage: AppTokenUsage?
    /// Tool activity log precomputed by the Rust reducer in
    /// `extract_conversation_activity` (shared/rust-bridge/.../boundary.rs).
    /// The iOS home card used to redo this walk client-side — that was the
    /// dominant AttributeGraph subscription during streaming. Using the
    /// Rust-side log removes every `appModel.snapshot` read from the card
    /// at zoom 1–3.
    let recentToolLog: [AppToolLogEntry]
    /// Bounds of the most recent turn. Rust emits these in milliseconds
    /// since epoch alongside `recent_tool_log`; we project into `Date` so
    /// the zoom-4 stopwatch chip can render durations without reading
    /// `appModel.snapshot`. `end` is `nil` when the turn is still active
    /// — the chip then drives its own live ticker.
    let lastTurnStart: Date?
    let lastTurnEnd: Date?

    var id: ThreadKey { key }
}

struct HomeDashboardServer: Identifiable, Equatable {
    let id: String
    let displayName: String
    let host: String
    let port: UInt16
    let isLocal: Bool
    let hasIpc: Bool
    let health: AppServerHealth
    let sourceLabel: String
    let statusLabel: String
    let statusColor: Color
    let statusDotState: StatusDotState

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

    static func == (lhs: HomeDashboardServer, rhs: HomeDashboardServer) -> Bool {
        lhs.id == rhs.id &&
            lhs.displayName == rhs.displayName &&
            lhs.host == rhs.host &&
            lhs.port == rhs.port &&
            lhs.isLocal == rhs.isLocal &&
            lhs.hasIpc == rhs.hasIpc &&
            lhs.health == rhs.health &&
            lhs.sourceLabel == rhs.sourceLabel &&
            lhs.statusLabel == rhs.statusLabel
    }
}

@MainActor
enum HomeDashboardSupport {
    static func recentConnectedSessions(
        from sessions: [AppSessionSummary],
        serversById: [String: HomeDashboardServer],
        limit: Int? = 10
    ) -> [HomeDashboardRecentSession] {
        let sorted = sessions
            .filter { serversById[$0.key.serverId] != nil }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .compactMap { session -> HomeDashboardRecentSession? in
                guard let server = serversById[session.key.serverId] else { return nil }
                return HomeDashboardRecentSession(
                    key: session.key,
                    serverId: session.key.serverId,
                    serverDisplayName: server.displayName,
                    isLocal: server.isLocal,
                    sessionTitle: sessionTitle(for: session),
                    preview: session.preview,
                    cwd: session.cwd,
                    model: session.model,
                    agentLabel: session.agentDisplayLabel,
                    updatedAt: Date(timeIntervalSince1970: TimeInterval(session.updatedAt ?? 0)),
                    hasTurnActive: session.hasActiveTurn,
                    isSubagent: session.isSubagent,
                    isFork: session.isFork,
                    lastResponsePreview: session.lastResponsePreview,
                    lastResponseTurnId: session.lastResponseTurnId,
                    lastUserMessage: session.lastUserMessage,
                    lastToolLabel: session.lastToolLabel,
                    stats: session.stats,
                    tokenUsage: session.tokenUsage,
                    recentToolLog: session.recentToolLog,
                    lastTurnStart: session.lastTurnStartMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) },
                    lastTurnEnd: session.hasActiveTurn
                        ? nil
                        : session.lastTurnEndMs.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
                )
            }
        if let limit { return Array(sorted.prefix(limit)) }
        return sorted
    }

    static func sortedConnectedServers(
        from servers: [AppServerSnapshot],
        activeServerId: String?
    ) -> [HomeDashboardServer] {
        var seenServerKeys: Set<String> = []

        return servers
            .filter { $0.health != .disconnected || $0.connectionProgress != nil }
            .map { server in
                HomeDashboardServer(
                    id: server.serverId,
                    displayName: server.displayName,
                    host: server.host,
                    port: server.port,
                    isLocal: server.isLocal,
                    hasIpc: server.hasIpc,
                    health: server.health,
                    sourceLabel: server.connectionModeLabel,
                    statusLabel: server.statusLabel,
                    statusColor: server.statusColor,
                    statusDotState: server.statusDotState
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
        let trimmedTitle = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && trimmedTitle != "Untitled session" {
            return trimmedTitle
        }

        let trimmedPreview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPreview.isEmpty { return trimmedPreview }

        if let userMessage = session.lastUserMessage?.trimmingCharacters(in: .whitespacesAndNewlines),
           !userMessage.isEmpty {
            return userMessage
        }

        return "New thread"
    }
}
