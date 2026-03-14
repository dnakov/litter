import Foundation
import Combine
import ActivityKit
import UIKit
import UserNotifications

struct SkillMentionSelection: Equatable {
    let name: String
    let path: String
}

enum AgentLabelFormatter {
    static func format(
        nickname: String?,
        role: String?,
        fallbackIdentifier: String? = nil
    ) -> String? {
        let cleanNickname = sanitized(nickname)
        let cleanRole = sanitized(role)
        switch (cleanNickname, cleanRole) {
        case let (nickname?, role?):
            return "\(nickname) [\(role)]"
        case let (nickname?, nil):
            return nickname
        case let (nil, role?):
            return "[\(role)]"
        default:
            return sanitized(fallbackIdentifier)
        }
    }

    static func sanitized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func looksLikeDisplayLabel(_ raw: String?) -> Bool {
        guard let value = sanitized(raw),
              value.hasSuffix("]"),
              let openBracket = value.lastIndex(of: "[") else {
            return false
        }
        let nickname = value[..<openBracket].trimmingCharacters(in: .whitespacesAndNewlines)
        let roleStart = value.index(after: openBracket)
        let roleEnd = value.index(before: value.endIndex)
        let role = value[roleStart..<roleEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        return !nickname.isEmpty && !role.isEmpty
    }
}

@MainActor
final class ServerManager: ObservableObject {
    @Published var connections: [String: ServerConnection] = [:]
    @Published var threads: [ThreadKey: ThreadState] = [:]
    @Published var activeThreadKey: ThreadKey?
    @Published var pendingApprovals: [PendingApproval] = []
    @Published var composerPrefillRequest: ComposerPrefillRequest?
    @Published private(set) var agentDirectoryVersion: Int = 0

    private var connectionSubscriptions: [String: AnyCancellable] = [:]
    private let savedServersKey = "codex_saved_servers"
    private var threadSubscriptions: [ThreadKey: AnyCancellable] = [:]
    private var liveItemMessageIndices: [ThreadKey: [String: Int]] = [:]
    private var liveTurnDiffMessageIndices: [ThreadKey: [String: Int]] = [:]
    private var serversUsingItemNotifications: Set<String> = []
    private var threadTurnCounts: [ThreadKey: Int] = [:]
    private var agentDirectory = AgentDirectory()
    private static let tsFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    private var ts: String { Self.tsFormatter.string(from: Date()) }
    private var backgroundedTurnKeys: Set<ThreadKey> = []
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var bgWakeCount: Int = 0
    private var liveActivities: [ThreadKey: Activity<CodexTurnAttributes>] = [:]
    private var liveActivityStartDates: [ThreadKey: Date] = [:]
    private var liveActivityToolCallCounts: [ThreadKey: Int] = [:]
    private var liveActivityOutputSnippets: [ThreadKey: String] = [:]
    private var liveActivityLastUpdateTimes: [ThreadKey: CFAbsoluteTime] = [:]
    private var liveActivityFileChangeCounts: [ThreadKey: Int] = [:]
    private var notificationPermissionRequested = false
    private let pushProxy = PushProxyClient()
    private var pushProxyRegistrationId: String?
    private var suppressNotifications = false
    var devicePushToken: Data?

    private struct PersistedContextUsageSnapshot: Decodable {
        let contextTokens: Int64?
        let modelContextWindow: Int64?
    }

    private struct AgentDirectoryEntry: Equatable {
        var nickname: String?
        var role: String?
        var threadId: String?
        var agentId: String?

        func merged(over existing: AgentDirectoryEntry?) -> AgentDirectoryEntry {
            AgentDirectoryEntry(
                nickname: nickname ?? existing?.nickname,
                role: role ?? existing?.role,
                threadId: threadId ?? existing?.threadId,
                agentId: agentId ?? existing?.agentId
            )
        }
    }

    private struct AgentDirectory {
        var byThreadId: [String: AgentDirectoryEntry] = [:]
        var byAgentId: [String: AgentDirectoryEntry] = [:]

        mutating func removeServer(_ serverId: String) {
            let prefix = "\(serverId):"
            byThreadId = byThreadId.filter { !$0.key.hasPrefix(prefix) }
            byAgentId = byAgentId.filter { !$0.key.hasPrefix(prefix) }
        }
    }

    enum ApprovalKind: String, Codable {
        case commandExecution
        case fileChange
    }

    enum ApprovalDecision: String {
        case accept
        case acceptForSession
        case decline
        case cancel
    }

    struct PendingApproval: Identifiable, Equatable {
        let id: String
        let requestId: String
        let serverId: String
        let method: String
        let kind: ApprovalKind
        let threadId: String?
        let turnId: String?
        let itemId: String?
        let command: String?
        let cwd: String?
        let reason: String?
        let grantRoot: String?
        let requesterAgentNickname: String?
        let requesterAgentRole: String?
        let createdAt: Date
    }

    struct ComposerPrefillRequest: Identifiable, Equatable {
        let id = UUID()
        let text: String
    }

    /// Call after inserting a new ThreadState into `threads` to forward its changes.
    private func observeThread(_ thread: ThreadState) {
        threadSubscriptions[thread.key] = thread.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Forward nested connection changes so views observing ServerManager refresh when
    /// connection-owned published values (auth/models/oauth) change.
    private func observeConnection(_ connection: ServerConnection, serverId: String) {
        connectionSubscriptions[serverId] = connection.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var sortedThreads: [ThreadState] {
        threads.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    var activeThread: ThreadState? {
        activeThreadKey.flatMap { threads[$0] }
    }

    var activeConnection: ServerConnection? {
        activeThreadKey.flatMap { connections[$0.serverId] }
    }

    var activePendingApproval: PendingApproval? {
        pendingApprovals.first
    }

    var hasAnyConnection: Bool {
        connections.values.contains { $0.isConnected }
    }

    private func debugAgentDirectoryLog(_ message: @autoclosure () -> String) {
        _ = message
    }

    private func logTargetResolution(targetId: String, resolvedLabel: String?, reason: String) {
        let label = resolvedLabel ?? "<nil>"
        debugAgentDirectoryLog("targetId=\(targetId) resolvedLabel=\(label) \(reason)")
    }

    private func agentDirectoryServerScope(_ serverId: String?) -> String? {
        sanitizedLineageId(serverId) ?? sanitizedLineageId(activeThreadKey?.serverId)
    }

    private func agentDirectoryScopedKey(serverId: String, id: String) -> String {
        "\(serverId):\(id)"
    }

    func resolvedAgentTargetLabel(for target: String, serverId: String? = nil) -> String? {
        if AgentLabelFormatter.looksLikeDisplayLabel(target),
           let label = AgentLabelFormatter.sanitized(target) {
            logTargetResolution(
                targetId: label,
                resolvedLabel: label,
                reason: "resolved-via=preformatted-target"
            )
            return label
        }
        guard let normalizedTarget = sanitizedLineageId(target) else {
            logTargetResolution(
                targetId: target,
                resolvedLabel: nil,
                reason: "unresolved reason=empty-target"
            )
            return nil
        }
        let serverScope = agentDirectoryServerScope(serverId)
        if let entry = mergedAgentDirectoryEntry(serverId: serverScope, threadId: normalizedTarget, agentId: normalizedTarget) {
            let label = AgentLabelFormatter.format(
                nickname: entry.nickname,
                role: entry.role,
                fallbackIdentifier: entry.threadId ?? entry.agentId ?? normalizedTarget
            )
            logTargetResolution(
                targetId: normalizedTarget,
                resolvedLabel: label,
                reason: "resolved-via=agent-directory"
            )
            return label
        }
        let threadMatch: ThreadState?
        if let serverScope {
            threadMatch = threads.values.first(where: { $0.serverId == serverScope && $0.threadId == normalizedTarget })
        } else {
            threadMatch = threads.values.first(where: { $0.threadId == normalizedTarget })
        }
        if let thread = threadMatch {
            let label = AgentLabelFormatter.format(
                nickname: thread.agentNickname,
                role: thread.agentRole,
                fallbackIdentifier: normalizedTarget
            )
            logTargetResolution(
                targetId: normalizedTarget,
                resolvedLabel: label,
                reason: "resolved-via=thread-state"
            )
            return label
        }
        logTargetResolution(
            targetId: normalizedTarget,
            resolvedLabel: nil,
            reason: "unresolved reason=no-agent-directory-or-thread-match serverScope=\(serverScope ?? "<nil>")"
        )
        return nil
    }

    // MARK: - Server Lifecycle

    func addServer(_ server: DiscoveredServer, target: ConnectionTarget) async {
        if let existing = connections[server.id] {
            if existing.server == server && existing.target == target {
                configureConnectionCallbacks(existing, serverId: server.id)
                if !existing.isConnected {
                    await existing.connect()
                    if existing.isConnected {
                        await refreshSessions(for: server.id)
                    }
                }
                return
            }

            existing.disconnect()
            connections.removeValue(forKey: server.id)
            connectionSubscriptions.removeValue(forKey: server.id)
        }

        let conn = ServerConnection(server: server, target: target)
        configureConnectionCallbacks(conn, serverId: server.id)
        connections[server.id] = conn
        saveServerList()
        await conn.connect()
        if conn.isConnected {
            await refreshSessions(for: server.id)
        }
    }

    private func configureConnectionCallbacks(_ conn: ServerConnection, serverId: String) {
        observeConnection(conn, serverId: serverId)
        conn.onNotification = { [weak self] method, data in
            self?.handleNotification(serverId: serverId, method: method, data: data)
        }
        conn.onServerRequest = { [weak self] requestId, method, data in
            self?.handleServerRequest(
                serverId: serverId,
                requestId: requestId,
                method: method,
                data: data
            ) ?? false
        }
        conn.onDisconnect = { [weak self] in
            NSLog("[%@ ws] disconnected server=%@", self?.ts ?? "?", serverId)
            self?.removePendingApprovals(forServerId: serverId)
            self?.objectWillChange.send()
        }
    }

    func removeServer(id: String) {
        if let conn = connections[id] {
            if conn.target == .local {
                Task { await CodexBridge.shared.stop() }
            } else if conn.server.source == .ssh {
                Task { await SSHSessionManager.shared.stopRemoteServer() }
            }
        }
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        connectionSubscriptions.removeValue(forKey: id)
        removePendingApprovals(forServerId: id)
        for key in threads.keys where key.serverId == id {
            threadSubscriptions.removeValue(forKey: key)
            liveItemMessageIndices.removeValue(forKey: key)
            liveTurnDiffMessageIndices.removeValue(forKey: key)
            threadTurnCounts.removeValue(forKey: key)
        }
        serversUsingItemNotifications.remove(id)
        let directoryEntryCount = agentDirectory.byThreadId.count + agentDirectory.byAgentId.count
        agentDirectory.removeServer(id)
        let updatedDirectoryEntryCount = agentDirectory.byThreadId.count + agentDirectory.byAgentId.count
        if updatedDirectoryEntryCount != directoryEntryCount {
            agentDirectoryVersion = agentDirectoryVersion &+ 1
        }
        threads = threads.filter { $0.key.serverId != id }
        if activeThreadKey?.serverId == id {
            activeThreadKey = nil
        }
        saveServerList()
    }

    func reconnectAll() async {
        let saved = loadSavedServers()
        await withTaskGroup(of: Void.self) { group in
            for s in saved {
                let server = s.toDiscoveredServer()
                if server.source == .local && !OnDeviceCodexFeature.isEnabled {
                    continue
                }
                guard let target = server.connectionTarget else { continue }
                group.addTask { @MainActor in
                    await self.addServer(server, target: target)
                }
            }
        }
    }

    // MARK: - Thread Lifecycle

    func startThread(
        serverId: String,
        cwd: String,
        model: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil,
        dynamicTools: [DynamicToolSpec]? = nil
    ) async throws -> ThreadKey {
        guard let conn = connections[serverId] else {
            throw NSError(domain: "Litter", code: 1, userInfo: [NSLocalizedDescriptionKey: "No connection for server"])
        }
        let resp = try await conn.startThread(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            dynamicTools: dynamicTools ?? (ExperimentalFeatures.shared.isEnabled(.generativeUI) ? GenerativeUITools.buildDynamicToolSpecs() : nil)
        )
        let threadId = resp.thread.id
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        let state = ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.cwd = resp.cwd
        state.model = resp.model
        state.modelProvider = resp.modelProvider ?? resp.model
        state.reasoningEffort = resp.reasoningEffort
        state.rolloutPath = resp.thread.path
        state.parentThreadId = sanitizedLineageId(resp.thread.parentThreadId)
        state.rootThreadId = sanitizedLineageId(resp.thread.rootThreadId)
        state.agentNickname = sanitizedLineageId(resp.thread.agentNickname)
        state.agentRole = sanitizedLineageId(resp.thread.agentRole)
        upsertAgentDirectory(
            serverId: serverId,
            threadId: threadId,
            agentId: resp.thread.agentId,
            nickname: state.agentNickname,
            role: state.agentRole
        )
        state.updatedAt = Date()
        threads[key] = state
        threadTurnCounts[key] = 0
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
        observeThread(state)
        activeThreadKey = key
        await refreshThreadContextWindow(for: key, cwd: resp.cwd)
        await refreshPersistedContextUsage(for: key)
        return key
    }

    func resumeThread(
        serverId: String,
        threadId: String,
        cwd: String,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async -> Bool {
        guard let conn = connections[serverId] else { return false }
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        let state = threads[key] ?? ThreadState(
            serverId: serverId,
            threadId: threadId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        state.status = .connecting
        threads[key] = state
        observeThread(state)
        do {
            let resp = try await conn.resumeThread(
                threadId: threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
            state.messages = restoredMessages(
                from: resp.thread.turns,
                serverId: serverId,
                defaultAgentNickname: resp.thread.agentNickname,
                defaultAgentRole: resp.thread.agentRole
            )
            threadTurnCounts[key] = resp.thread.turns.count
            liveItemMessageIndices[key] = nil
            liveTurnDiffMessageIndices[key] = nil
            state.cwd = resp.cwd
            state.model = resp.model
            state.modelProvider = resp.modelProvider ?? resp.model
            state.reasoningEffort = resp.reasoningEffort
            state.rolloutPath = resp.thread.path ?? state.rolloutPath
            state.parentThreadId = sanitizedLineageId(resp.thread.parentThreadId)
            state.rootThreadId = sanitizedLineageId(resp.thread.rootThreadId)
            state.agentNickname = sanitizedLineageId(resp.thread.agentNickname)
            state.agentRole = sanitizedLineageId(resp.thread.agentRole)
            upsertAgentDirectory(
                serverId: serverId,
                threadId: threadId,
                agentId: resp.thread.agentId,
                nickname: state.agentNickname,
                role: state.agentRole
            )
            state.status = .ready
            state.updatedAt = Date()
            activeThreadKey = key
            await refreshThreadContextWindow(for: key, cwd: resp.cwd)
            await refreshPersistedContextUsage(for: key)
            return true
        } catch {
            state.status = .error(error.localizedDescription)
            return false
        }
    }

    func viewThread(
        _ key: ThreadKey,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async {
        if threads[key]?.messages.isEmpty == true {
            let cwd = threads[key]?.cwd ?? "/tmp"
            _ = await resumeThread(
                serverId: key.serverId,
                threadId: key.threadId,
                cwd: cwd,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
        } else {
            activeThreadKey = key
            let cwd = threads[key]?.cwd ?? "/tmp"
            await refreshThreadContextWindow(for: key, cwd: cwd)
            await refreshPersistedContextUsage(for: key)
        }
    }

    func forkThread(
        _ sourceKey: ThreadKey,
        cwd: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let sourceThread = threads[sourceKey] else {
            throw NSError(domain: "Litter", code: 1010, userInfo: [NSLocalizedDescriptionKey: "Source thread not found"])
        }
        guard !sourceThread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1011, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before forking"])
        }
        guard let conn = connections[sourceKey.serverId] else {
            throw NSError(domain: "Litter", code: 1012, userInfo: [NSLocalizedDescriptionKey: "No active server connection for this thread"])
        }

        let preferredCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let forkCwd = (preferredCwd?.isEmpty == false) ? preferredCwd : sourceThread.cwd
        let response = try await conn.forkThread(
            threadId: sourceKey.threadId,
            cwd: forkCwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        let forkKey = ThreadKey(serverId: sourceKey.serverId, threadId: response.thread.id)
        let forkedState = threads[forkKey] ?? ThreadState(
            serverId: sourceKey.serverId,
            threadId: response.thread.id,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        forkedState.messages = restoredMessages(
            from: response.thread.turns,
            serverId: sourceKey.serverId,
            defaultAgentNickname: response.thread.agentNickname,
            defaultAgentRole: response.thread.agentRole
        )
        threadTurnCounts[forkKey] = response.thread.turns.count
        liveItemMessageIndices[forkKey] = nil
        liveTurnDiffMessageIndices[forkKey] = nil
        forkedState.cwd = response.cwd
        forkedState.preview = sourceThread.preview
        forkedState.model = response.model
        forkedState.modelProvider = response.modelProvider ?? response.model
        forkedState.reasoningEffort = response.reasoningEffort
        forkedState.rolloutPath = response.thread.path
        forkedState.parentThreadId = sanitizedLineageId(response.thread.parentThreadId) ?? sourceKey.threadId
        forkedState.rootThreadId = sanitizedLineageId(response.thread.rootThreadId)
            ?? sourceThread.rootThreadId
            ?? sourceThread.parentThreadId
            ?? sourceKey.threadId
        forkedState.agentNickname = sanitizedLineageId(response.thread.agentNickname)
        forkedState.agentRole = sanitizedLineageId(response.thread.agentRole)
        upsertAgentDirectory(
            serverId: sourceKey.serverId,
            threadId: response.thread.id,
            agentId: response.thread.agentId,
            nickname: forkedState.agentNickname,
            role: forkedState.agentRole
        )
        forkedState.status = .ready
        forkedState.updatedAt = Date()
        threads[forkKey] = forkedState
        observeThread(forkedState)
        activeThreadKey = forkKey
        await refreshThreadContextWindow(for: forkKey, cwd: response.cwd)
        await refreshPersistedContextUsage(for: forkKey)
        return forkKey
    }

    func forkActiveThread(
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let key = activeThreadKey,
              let thread = threads[key] else {
            throw NSError(domain: "Litter", code: 1013, userInfo: [NSLocalizedDescriptionKey: "No active thread to fork"])
        }
        return try await forkThread(
            key,
            cwd: thread.cwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
    }

    func forkFromMessage(
        _ message: ChatMessage,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async throws -> ThreadKey {
        guard let sourceKey = activeThreadKey,
              let sourceThread = threads[sourceKey] else {
            throw NSError(domain: "Litter", code: 1014, userInfo: [NSLocalizedDescriptionKey: "No active thread to fork"])
        }
        guard !sourceThread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1015, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before forking"])
        }
        guard message.role == .user, message.isFromUserTurnBoundary else {
            throw NSError(domain: "Litter", code: 1016, userInfo: [NSLocalizedDescriptionKey: "Fork from here is only supported for user messages"])
        }

        let rollbackDepth = try rollbackDepthForMessage(message, in: sourceKey)
        let forkKey = try await forkThread(
            sourceKey,
            cwd: sourceThread.cwd,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        guard rollbackDepth > 0 else { return forkKey }
        guard let forkConn = connections[forkKey.serverId],
              let forkThreadState = threads[forkKey] else {
            throw NSError(domain: "Litter", code: 1017, userInfo: [NSLocalizedDescriptionKey: "Forked thread unavailable"])
        }

        let rollbackResponse = try await forkConn.rollbackThread(threadId: forkKey.threadId, numTurns: rollbackDepth)
        forkThreadState.messages = restoredMessages(
            from: rollbackResponse.thread.turns,
            serverId: forkKey.serverId,
            defaultAgentNickname: rollbackResponse.thread.agentNickname ?? forkThreadState.agentNickname,
            defaultAgentRole: rollbackResponse.thread.agentRole ?? forkThreadState.agentRole
        )
        threadTurnCounts[forkKey] = rollbackResponse.thread.turns.count
        forkThreadState.status = .ready
        forkThreadState.updatedAt = Date()
        liveItemMessageIndices[forkKey] = nil
        liveTurnDiffMessageIndices[forkKey] = nil
        return forkKey
    }

    func editMessage(_ message: ChatMessage) async throws {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1018, userInfo: [NSLocalizedDescriptionKey: "No active thread to edit"])
        }
        guard !thread.hasTurnActive else {
            throw NSError(domain: "Litter", code: 1019, userInfo: [NSLocalizedDescriptionKey: "Wait for the active turn to finish before editing"])
        }
        guard message.role == .user, message.isFromUserTurnBoundary else {
            throw NSError(domain: "Litter", code: 1020, userInfo: [NSLocalizedDescriptionKey: "Only user messages can be edited"])
        }

        let rollbackDepth = try rollbackDepthForMessage(message, in: key)
        if rollbackDepth > 0 {
            let response = try await conn.rollbackThread(threadId: key.threadId, numTurns: rollbackDepth)
            thread.messages = restoredMessages(
                from: response.thread.turns,
                serverId: key.serverId,
                defaultAgentNickname: response.thread.agentNickname ?? thread.agentNickname,
                defaultAgentRole: response.thread.agentRole ?? thread.agentRole
            )
            threadTurnCounts[key] = response.thread.turns.count
            thread.status = .ready
            thread.updatedAt = Date()
            liveItemMessageIndices[key] = nil
            liveTurnDiffMessageIndices[key] = nil
        }
        composerPrefillRequest = ComposerPrefillRequest(text: message.text)
    }

    // MARK: - Approvals

    func respondToPendingApproval(requestId: String, decision: ApprovalDecision) {
        guard let index = pendingApprovals.firstIndex(where: { $0.requestId == requestId }) else { return }
        let approval = pendingApprovals.remove(at: index)
        let decisionValue: String
        switch approval.method {
        case "execCommandApproval", "applyPatchApproval":
            switch decision {
            case .accept: decisionValue = "approved"
            case .acceptForSession: decisionValue = "approved_for_session"
            case .decline: decisionValue = "denied"
            case .cancel: decisionValue = "abort"
            }
        default:
            decisionValue = decision.rawValue
        }
        connections[approval.serverId]?.respondToServerRequest(
            id: approval.requestId,
            result: ["decision": decisionValue]
        )
    }

    private func handleServerRequest(serverId: String, requestId: String, method: String, data: Data) -> Bool {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return false
        }
        let params = root["params"] as? [String: Any] ?? [:]

        let pending: PendingApproval
        switch method {
        case "item/commandExecution/requestApproval":
            let command = commandString(from: params)
            let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: threadId,
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "cmdId", "cmd_id"]),
                command: command?.isEmpty == true ? nil : command,
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "item/fileChange/requestApproval":
            let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: threadId,
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "patchId", "patch_id"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot", "grant_root"]),
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "execCommandApproval":
            let threadId = extractString(params, keys: ["conversationId", "threadId"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: threadId,
                turnId: nil,
                itemId: extractString(params, keys: ["approvalId", "callId", "cmdId"]),
                command: commandString(from: params),
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "applyPatchApproval":
            let threadId = extractString(params, keys: ["conversationId", "threadId"])
            let requester = resolveAgentIdentity(serverId: serverId, threadId: threadId, params: params)
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: threadId,
                turnId: nil,
                itemId: extractString(params, keys: ["callId", "patchId"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot"]),
                requesterAgentNickname: requester.nickname,
                requesterAgentRole: requester.role,
                createdAt: Date()
            )
        case "item/tool/call":
            return handleDynamicToolCall(serverId: serverId, requestId: requestId, params: params)
        default:
            return false
        }

        pendingApprovals.append(pending)
        return true
    }

    // MARK: - Dynamic Tool Calls

    private func handleDynamicToolCall(serverId: String, requestId: String, params: [String: Any]) -> Bool {
        guard let toolCallParams = DynamicToolCallParams(from: params) else {
            return false
        }

        let threadId = toolCallParams.threadId
        let key = ThreadKey(serverId: serverId, threadId: threadId)

        switch toolCallParams.tool {
        case GenerativeUITools.readMeToolName:
            handleReadMeToolCall(serverId: serverId, requestId: requestId, params: toolCallParams)
            return true
        case GenerativeUITools.showWidgetToolName:
            handleShowWidgetToolCall(serverId: serverId, requestId: requestId, key: key, params: toolCallParams)
            return true
        default:
            connections[serverId]?.respondToServerRequest(
                id: requestId,
                result: DynamicToolCallResponse.error("Unknown dynamic tool: \(toolCallParams.tool)").asDictionary
            )
            return true
        }
    }

    private func handleReadMeToolCall(serverId: String, requestId: String, params: DynamicToolCallParams) {
        let modulesArg = params.arguments["modules"] as? [String] ?? []
        let modules = modulesArg.compactMap { WidgetGuidelineModule(rawValue: $0) }
        let guidelines = WidgetGuidelines.getGuidelines(modules: modules.isEmpty ? [.interactive] : modules)
        connections[serverId]?.respondToServerRequest(
            id: requestId,
            result: DynamicToolCallResponse.text(guidelines).asDictionary
        )
    }

    private func handleShowWidgetToolCall(serverId: String, requestId: String, key: ThreadKey, params: DynamicToolCallParams) {
        guard let thread = threads[key] else {
            connections[serverId]?.respondToServerRequest(
                id: requestId,
                result: DynamicToolCallResponse.error("Thread not found").asDictionary
            )
            return
        }

        let widget = WidgetState.fromArguments(params.arguments, callId: params.callId, isFinalized: true)

        // Use liveItemMessageIndices for O(1) lookup instead of linear scan
        if let index = liveItemMessageIndices[key]?[params.callId],
           thread.messages.indices.contains(index) {
            thread.messages[index].widgetState = widget
            thread.messages[index].text = "### Widget\nstatus: completed\n\nWidget: \(widget.title)"
        } else {
            thread.messages.append(ChatMessage(
                role: .system,
                text: "### Widget\nstatus: completed\n\nWidget: \(widget.title)",
                widgetState: widget
            ))
        }

        thread.updatedAt = Date()

        connections[serverId]?.respondToServerRequest(
            id: requestId,
            result: DynamicToolCallResponse.text("Widget \"\(widget.title)\" rendered and shown to the user (\(Int(widget.width))x\(Int(widget.height))).").asDictionary
        )
    }

    private func commandString(from params: [String: Any]) -> String? {
        if let command = extractString(params, keys: ["command"]), !command.isEmpty {
            return command
        }
        if let array = params["command"] as? [String], !array.isEmpty {
            return array.joined(separator: " ")
        }
        if let array = params["command"] as? [Any] {
            let parts = array.compactMap { value -> String? in
                if let text = value as? String {
                    return text
                }
                if let number = value as? NSNumber {
                    return number.stringValue
                }
                return nil
            }
            if !parts.isEmpty {
                return parts.joined(separator: " ")
            }
        }
        return nil
    }

    private func removePendingApprovals(forServerId serverId: String) {
        pendingApprovals.removeAll { $0.serverId == serverId }
    }

    // MARK: - Send / Interrupt

    func send(
        _ text: String,
        skillMentions: [SkillMentionSelection] = [],
        cwd: String,
        model: String? = nil,
        effort: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async {
        var key = activeThreadKey
        if key == nil {
            guard let serverId = connections.values.first(where: { $0.isConnected })?.id else { return }
            do {
                key = try await startThread(
                    serverId: serverId,
                    cwd: cwd,
                    model: model,
                    approvalPolicy: approvalPolicy,
                    sandboxMode: sandboxMode,
                    dynamicTools: ExperimentalFeatures.shared.isEnabled(.generativeUI) ? GenerativeUITools.buildDynamicToolSpecs() : nil
                )
            } catch {
                let conn = connections[serverId]
                let errorKey = ThreadKey(serverId: serverId, threadId: "error-\(UUID().uuidString)")
                let state = ThreadState(
                    serverId: serverId,
                    threadId: errorKey.threadId,
                    serverName: conn?.server.name ?? "Server",
                    serverSource: conn?.server.source ?? .local
                )
                state.messages.append(ChatMessage(role: .user, text: text, isFromUserTurnBoundary: true))
                state.messages.append(ChatMessage(role: .system, text: error.localizedDescription))
                state.status = .error(error.localizedDescription)
                threads[errorKey] = state
                observeThread(state)
                activeThreadKey = errorKey
                return
            }
        }
        guard let key, let thread = threads[key], let conn = connections[key.serverId] else { return }
        thread.messages.append(ChatMessage(role: .user, text: text, isFromUserTurnBoundary: true))
        thread.status = .thinking
        thread.updatedAt = Date()
        requestNotificationPermissionIfNeeded()
        startLiveActivity(key: key, model: thread.model, cwd: thread.cwd, prompt: text)
        do {
            let skillInputs = skillMentions.map { mention in
                UserInput(type: "skill", path: mention.path, name: mention.name)
            }
            let resp = try await conn.sendTurn(
                threadId: key.threadId,
                text: text,
                model: model,
                effort: effort,
                additionalInput: skillInputs
            )
            NSLog("[send] sendTurn succeeded, turnId=%@", resp.turnId ?? "nil")
            thread.activeTurnId = resp.turnId
        } catch {
            thread.status = .error(error.localizedDescription)
            endLiveActivity(key: key, phase: .failed)
        }
    }

    func startReviewOnActiveThread() async throws {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1001, userInfo: [NSLocalizedDescriptionKey: "No active thread to review"])
        }
        thread.status = .thinking
        do {
            _ = try await conn.startReview(threadId: key.threadId)
        } catch {
            thread.status = .error(error.localizedDescription)
            throw error
        }
    }

    func renameActiveThread(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Litter", code: 1002, userInfo: [NSLocalizedDescriptionKey: "Thread name cannot be empty"])
        }
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1003, userInfo: [NSLocalizedDescriptionKey: "No active thread to rename"])
        }
        try await conn.setThreadName(threadId: key.threadId, name: trimmed)
        thread.preview = trimmed
        thread.updatedAt = Date()
    }

    func renameThread(_ key: ThreadKey, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw NSError(domain: "Litter", code: 1030, userInfo: [NSLocalizedDescriptionKey: "Thread name cannot be empty"])
        }
        guard let thread = threads[key],
              let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1031, userInfo: [NSLocalizedDescriptionKey: "Thread unavailable"])
        }
        try await conn.setThreadName(threadId: key.threadId, name: trimmed)
        thread.preview = trimmed
        thread.updatedAt = Date()
    }

    func archiveThread(_ key: ThreadKey) async throws {
        guard let conn = connections[key.serverId] else {
            throw NSError(domain: "Litter", code: 1032, userInfo: [NSLocalizedDescriptionKey: "Server unavailable"])
        }
        try await conn.archiveThread(threadId: key.threadId)
        threads.removeValue(forKey: key)
        threadSubscriptions.removeValue(forKey: key)
        threadTurnCounts.removeValue(forKey: key)
        liveItemMessageIndices.removeValue(forKey: key)
        liveTurnDiffMessageIndices.removeValue(forKey: key)
        if activeThreadKey == key {
            activeThreadKey = sortedThreads.first?.key
        }
    }

    func interrupt() async {
        guard let key = activeThreadKey,
              let thread = threads[key],
              let conn = connections[key.serverId] else { return }
        guard let turnId = thread.activeTurnId else { return }
        await conn.interrupt(threadId: key.threadId, turnId: turnId)
    }

    // MARK: - Session Refresh

    func refreshAllSessions() async {
        await withTaskGroup(of: Void.self) { group in
            for serverId in connections.keys {
                group.addTask { @MainActor in
                    await self.refreshSessions(for: serverId)
                }
            }
        }
    }

    func refreshSessions(for serverId: String) async {
        guard let conn = connections[serverId], conn.isConnected else { return }
        do {
            let resp = try await conn.listThreads()
            for summary in resp.data {
                let key = ThreadKey(serverId: serverId, threadId: summary.id)
                if let existing = threads[key] {
                    existing.preview = summary.preview
                    existing.cwd = summary.cwd
                    existing.rolloutPath = summary.path ?? existing.rolloutPath
                    existing.modelProvider = summary.modelProvider
                    existing.parentThreadId = sanitizedLineageId(summary.parentThreadId) ?? existing.parentThreadId
                    existing.rootThreadId = sanitizedLineageId(summary.rootThreadId) ?? existing.rootThreadId
                    existing.agentNickname = sanitizedLineageId(summary.agentNickname) ?? existing.agentNickname
                    existing.agentRole = sanitizedLineageId(summary.agentRole) ?? existing.agentRole
                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: summary.id,
                        agentId: summary.agentId,
                        nickname: existing.agentNickname,
                        role: existing.agentRole
                    )
                    existing.updatedAt = Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))
                } else {
                    let state = ThreadState(
                        serverId: serverId,
                        threadId: summary.id,
                        serverName: conn.server.name,
                        serverSource: conn.server.source
                    )
                    state.preview = summary.preview
                    state.cwd = summary.cwd
                    state.rolloutPath = summary.path
                    state.modelProvider = summary.modelProvider
                    state.parentThreadId = sanitizedLineageId(summary.parentThreadId)
                    state.rootThreadId = sanitizedLineageId(summary.rootThreadId)
                    state.agentNickname = sanitizedLineageId(summary.agentNickname)
                    state.agentRole = sanitizedLineageId(summary.agentRole)
                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: summary.id,
                        agentId: summary.agentId,
                        nickname: state.agentNickname,
                        role: state.agentRole
                    )
                    state.updatedAt = Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))
                    threads[key] = state
                    threadTurnCounts[key] = threadTurnCounts[key] ?? 0
                    observeThread(state)
                }
            }
        } catch {}
    }

    // MARK: - Notification Routing

    func handleNotification(serverId: String, method: String, data: Data) {
        if suppressNotifications {
            return
        }
        switch method {
        case "account/login/completed", "account/updated", "account/rateLimits/updated":
            connections[serverId]?.handleAccountNotification(method: method, data: data)

        case "sessionConfigured":
            handleSessionConfiguredNotification(serverId: serverId, data: data)

        case "thread/tokenUsage/updated":
            handleThreadTokenUsageUpdatedNotification(serverId: serverId, data: data)

        case "turn/started":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .thinking
                threads[key]?.activeTurnId = extractTurnId(from: data)
            }

        case "item/agentMessage/delta":
            serversUsingItemNotifications.insert(serverId)
            struct DeltaParams: Decodable {
                let delta: String
                let threadId: String?
                let agentId: String?
                let agentNickname: String?
                let agentRole: String?

                private enum CodingKeys: String, CodingKey {
                    case delta
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
                    case type
                }

                init(from decoder: Decoder) throws {
                    let container = try decoder.container(keyedBy: CodingKeys.self)
                    let sourceAny = try? container.decodeIfPresent(AnyCodable.self, forKey: .source)
                    delta = (try? container.decode(String.self, forKey: .delta)) ?? ""
                    threadId = Self.decodeString(container, forKey: .threadId)
                        ?? Self.decodeString(container, forKey: .threadIdSnake)
                        ?? Self.extractSourceField(sourceAny?.value, keys: ["thread_id", "threadId"])

                    let directAgentId = Self.decodeString(container, forKey: .agentId)
                        ?? Self.decodeString(container, forKey: .agentIdSnake)
                        ?? Self.decodeString(container, forKey: .id)
                    agentId = directAgentId
                        ?? Self.extractSourceField(sourceAny?.value, keys: ["agent_id", "agentId", "id"])

                    let directNickname = Self.decodeString(container, forKey: .agentNickname)
                        ?? Self.decodeString(container, forKey: .agentNicknameSnake)
                        ?? Self.decodeString(container, forKey: .nickname)
                        ?? Self.decodeString(container, forKey: .name)
                    agentNickname = directNickname
                        ?? Self.extractSourceField(sourceAny?.value, keys: ["agent_nickname", "agentNickname", "nickname", "name"])

                    let roleFromPrimary = try? container.decodeIfPresent(String.self, forKey: .agentRole)
                    let roleFromSnake = try? container.decodeIfPresent(String.self, forKey: .agentRoleSnake)
                    let roleFromType = try? container.decodeIfPresent(String.self, forKey: .agentType)
                    let roleFromTypeSnake = try? container.decodeIfPresent(String.self, forKey: .agentTypeSnake)
                    let roleFromGeneric = try? container.decodeIfPresent(String.self, forKey: .role)
                    let typeFromGeneric = try? container.decodeIfPresent(String.self, forKey: .type)
                    let directRole = roleFromPrimary ?? roleFromSnake ?? roleFromType ?? roleFromTypeSnake ?? roleFromGeneric ?? typeFromGeneric
                    agentRole = directRole
                        ?? Self.extractSourceField(sourceAny?.value, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"])
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
                    return nil
                }

                private static func extractSourceField(_ source: Any?, keys: [String]) -> String? {
                    guard let sourceDict = source as? [String: Any] else { return nil }
                    let subAgent = (sourceDict["subAgent"] as? [String: Any]) ?? (sourceDict["sub_agent"] as? [String: Any])
                    guard let subAgent else { return nil }
                    let threadSpawn = (subAgent["thread_spawn"] as? [String: Any]) ?? (subAgent["threadSpawn"] as? [String: Any])

                    func extract(from dict: [String: Any]?) -> String? {
                        guard let dict else { return nil }
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
                        return nil
                    }

                    return extract(from: threadSpawn) ?? extract(from: subAgent)
                }
            }
            struct DeltaNotif: Decodable { let params: DeltaParams }
            guard let notif = try? JSONDecoder().decode(DeltaNotif.self, from: data),
                  !notif.params.delta.isEmpty else { return }
            let explicitThreadId = sanitizedLineageId(notif.params.threadId)
            let key = resolveThreadKey(serverId: serverId, threadId: explicitThreadId)
            guard let thread = threads[key] else { return }
            let agentId = sanitizedLineageId(notif.params.agentId)
            let agentNickname = sanitizedLineageId(notif.params.agentNickname) ?? thread.agentNickname
            let agentRole = sanitizedLineageId(notif.params.agentRole) ?? thread.agentRole
            debugAgentDirectoryLog(
                "delta parsed threadId=\(explicitThreadId ?? "<nil>") agentId=\(agentId ?? "<nil>") nickname=\(agentNickname ?? "<nil>") role=\(agentRole ?? "<nil>")"
            )
            if let last = thread.messages.last, last.role == .assistant {
                thread.messages[thread.messages.count - 1].text += notif.params.delta
                if thread.messages[thread.messages.count - 1].agentNickname == nil {
                    thread.messages[thread.messages.count - 1].agentNickname = agentNickname
                }
                if thread.messages[thread.messages.count - 1].agentRole == nil {
                    thread.messages[thread.messages.count - 1].agentRole = agentRole
                }
            } else {
                thread.messages.append(
                    ChatMessage(
                        role: .assistant,
                        text: notif.params.delta,
                        agentNickname: agentNickname,
                        agentRole: agentRole
                    )
                )
            }
            if explicitThreadId != nil || agentId == nil {
                thread.agentNickname = agentNickname
                thread.agentRole = agentRole
            }
            upsertAgentDirectory(
                serverId: serverId,
                threadId: explicitThreadId ?? (agentId == nil ? key.threadId : nil),
                agentId: agentId,
                nickname: agentNickname,
                role: agentRole
            )
            thread.updatedAt = Date()
            updateLiveActivityOutput(key: key, thread: thread)

        case "error", "codex/event/error":
            handleErrorNotification(serverId: serverId, data: data)

        case "turn/completed", "codex/event/task_complete":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .ready
                threads[key]?.updatedAt = Date()
                threads[key]?.activeTurnId = nil
                liveItemMessageIndices[key] = nil
                liveTurnDiffMessageIndices[key] = nil
                backgroundedTurnKeys.remove(key)
                endLiveActivity(key: key, phase: .completed)
                postLocalNotificationIfNeeded(model: threads[key]?.model ?? "", threadPreview: threads[key]?.preview)
                // Skip syncThreadFromServer — client already has all messages from streaming.
                // Sync happens on thread resume/switch instead.
            } else {
                for (_, thread) in threads where thread.serverId == serverId && thread.hasTurnActive {
                    thread.status = .ready
                    thread.updatedAt = Date()
                    thread.activeTurnId = nil
                    liveItemMessageIndices[thread.key] = nil
                    liveTurnDiffMessageIndices[thread.key] = nil
                    backgroundedTurnKeys.remove(thread.key)
                }
                endAllLiveActivities(phase: .completed)
                postLocalNotificationIfNeeded(model: "", threadPreview: nil)
            }
            Task { await connections[serverId]?.fetchRateLimits() }

        case "turn/diff/updated":
            handleTurnDiffNotification(serverId: serverId, data: data)

        default:
            if method.hasPrefix("item/") {
                handleItemNotification(serverId: serverId, method: method, data: data)
            } else if method == "codex/event/turn_diff" {
                handleLegacyCodexEventNotification(serverId: serverId, method: method, data: data)
            } else if method == "codex/event" || method.hasPrefix("codex/event/") {
                ingestCodexEventAgentMetadata(serverId: serverId, method: method, data: data)
                if !serversUsingItemNotifications.contains(serverId) {
                    handleLegacyCodexEventNotification(serverId: serverId, method: method, data: data)
                }
            }
        }
    }

    private func handleErrorNotification(serverId: String, data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let params = root["params"] as? [String: Any] else { return }

        let errorDict = params["error"] as? [String: Any]
        let message = (errorDict?["message"] as? String)
            ?? (params["message"] as? String)
            ?? "Unknown error"

        let threadId = extractString(params, keys: ["threadId", "thread_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        thread.messages.append(ChatMessage(role: .system, text: message))
        thread.status = .error(message)
        thread.updatedAt = Date()
        endLiveActivity(key: key, phase: .failed)
    }

    private func handleSessionConfiguredNotification(serverId: String, data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let params = root["params"] as? [String: Any],
              let sessionId = extractString(params, keys: ["sessionId", "session_id", "threadId", "thread_id"]),
              !sessionId.isEmpty else { return }

        guard let conn = connections[serverId] else { return }
        let key = ThreadKey(serverId: serverId, threadId: sessionId)
        let thread = threads[key] ?? ThreadState(
            serverId: serverId,
            threadId: sessionId,
            serverName: conn.server.name,
            serverSource: conn.server.source
        )
        let parentId = extractString(
            params,
            keys: ["forkedFromId", "forked_from_id", "parentThreadId", "parent_thread_id"]
        )
        let rootId = extractString(params, keys: ["rootThreadId", "root_thread_id"])
        let title = extractString(params, keys: ["threadName", "thread_name"])
        let cwd = extractString(params, keys: ["cwd"])
        let model = extractString(params, keys: ["model"])
        let modelProvider = extractString(params, keys: ["modelProvider", "model_provider", "modelProviderId", "model_provider_id"])
        let reasoningEffort = extractString(params, keys: ["reasoningEffort", "reasoning_effort"])
        let agentMetadata = extractAgentMetadata(params)

        thread.parentThreadId = sanitizedLineageId(parentId) ?? thread.parentThreadId
        thread.rootThreadId = sanitizedLineageId(rootId) ?? thread.rootThreadId
        thread.agentNickname = agentMetadata.nickname ?? thread.agentNickname
        thread.agentRole = agentMetadata.role ?? thread.agentRole
        upsertAgentDirectory(
            serverId: serverId,
            threadId: sessionId,
            agentId: agentMetadata.agentId,
            nickname: thread.agentNickname,
            role: thread.agentRole
        )
        if let title, !title.isEmpty {
            thread.preview = title
        }
        if let cwd, !cwd.isEmpty {
            thread.cwd = cwd
        }
        if let model, !model.isEmpty {
            thread.model = model
        }
        if let modelProvider, !modelProvider.isEmpty {
            thread.modelProvider = modelProvider
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            thread.reasoningEffort = reasoningEffort
        }

        threads[key] = thread
        observeThread(thread)
        let currentCwd = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentCwd.isEmpty {
            Task { @MainActor in
                await refreshThreadContextWindow(for: key, cwd: currentCwd)
            }
        }
    }

    private func handleThreadTokenUsageUpdatedNotification(serverId: String, data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let params = root["params"] as? [String: Any],
              let threadId = extractString(params, keys: ["threadId", "thread_id"]),
              !threadId.isEmpty else { return }

        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key],
              let tokenUsage = (params["tokenUsage"] as? [String: Any]) ?? (params["token_usage"] as? [String: Any]) else {
            return
        }

        if let modelContextWindow = extractInt64(tokenUsage, keys: ["modelContextWindow", "model_context_window"]) {
            thread.modelContextWindow = modelContextWindow
        }
        if let lastUsage = (tokenUsage["last"] as? [String: Any]) ?? (tokenUsage["last_token_usage"] as? [String: Any]),
           let contextTokens = extractInt64(lastUsage, keys: ["totalTokens", "total_tokens"]) {
            thread.contextTokensUsed = contextTokens
        }
    }

    private func handleItemNotification(serverId: String, method: String, data: Data) {
        // Format: item/started or item/completed → params.item has the ThreadItem with "type"
        //         item/agentMessage/delta handled separately in handleNotification.
        serversUsingItemNotifications.insert(serverId)
        struct ItemNotification: Decodable { let params: AnyCodable? }
        guard let raw = try? JSONDecoder().decode(ItemNotification.self, from: data),
              let paramsDict = raw.params?.value as? [String: Any] else { return }

        let threadId = extractString(paramsDict, keys: ["threadId", "thread_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        switch method {
        case "item/started", "item/completed":
            guard let itemDict = paramsDict["item"] as? [String: Any] else { return }
            let itemType = itemDict["type"] as? String ?? "unknown"
            // agentMessage is streamed via delta; userMessage is added locally in send()
            if itemType == "agentMessage" || itemType == "userMessage" {
                return
            }
            // Handle dynamicToolCall for show_widget — create a placeholder widget message
            if let itemType = itemDict["type"] as? String,
               itemType == "dynamicToolCall",
               let toolName = extractString(itemDict, keys: ["tool"]) {
                if toolName == GenerativeUITools.showWidgetToolName {
                    let itemId = extractString(itemDict, keys: ["id"]) ?? UUID().uuidString

                    if method == "item/completed" {
                        // On completion, preserve the existing widget message (already populated
                        // by handleShowWidgetToolCall). Just finalize and clear live tracking.
                        if let index = liveItemMessageIndices[key]?[itemId],
                           thread.messages.indices.contains(index) {
                            thread.messages[index].widgetState?.isFinalized = true
                        }
                        liveItemMessageIndices[key]?[itemId] = nil
                        thread.updatedAt = Date()
                        return
                    }

                    // item/started — create a placeholder widget with spinner
                    let args = itemDict["arguments"] as? [String: Any] ?? [:]
                    let widget = WidgetState.fromArguments(args, callId: itemId)
                    let msg = ChatMessage(
                        role: .system,
                        text: "### Widget\nstatus: inProgress\n\nWidget: \(widget.title)",
                        widgetState: widget
                    )
                    upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
                    thread.updatedAt = Date()
                    return
                }
                // visualize_read_me is invisible — skip it
                if toolName == GenerativeUITools.readMeToolName { return }
            }
            if method == "item/started", let itemType = itemDict["type"] as? String {
                let toolName: String
                if itemType == "commandExecution" || itemType == "command_execution",
                   let cmd = commandString(from: itemDict) {
                    toolName = cmd
                } else {
                    toolName = extractString(itemDict, keys: ["name", "toolName", "tool_name"]) ?? itemType
                }
                updateLiveActivity(key: key, phase: .toolCall, toolName: toolName)
            }
            guard let itemData = try? JSONSerialization.data(withJSONObject: itemDict),
                  let item = try? JSONDecoder().decode(ResumedThreadItem.self, from: itemData),
                  let msg = chatMessage(
                    from: item,
                    sourceTurnId: nil,
                    sourceTurnIndex: nil,
                    serverId: serverId,
                    defaultAgentNickname: thread.agentNickname,
                    defaultAgentRole: thread.agentRole
                  ) else { return }
            let itemId = extractString(itemDict, keys: ["id"])
            if method == "item/started", let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else if method == "item/completed", let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "item/commandExecution/outputDelta":
            guard let delta = extractString(paramsDict, keys: ["delta"]), !delta.isEmpty else { return }
            if let itemId = extractString(paramsDict, keys: ["itemId", "item_id"]),
               appendCommandOutputDelta(delta, itemId: itemId, key: key, thread: thread) {
                thread.updatedAt = Date()
                return
            }
            if let msg = systemMessage(title: "Command Output", body: "```text\n\(delta)\n```") {
                thread.messages.append(msg)
                thread.updatedAt = Date()
            }

        case "item/mcpToolCall/progress":
            guard let progress = extractString(paramsDict, keys: ["message"]), !progress.isEmpty else { return }
            if let itemId = extractString(paramsDict, keys: ["itemId", "item_id"]),
               appendMcpProgress(progress, itemId: itemId, key: key, thread: thread) {
                thread.updatedAt = Date()
                return
            }
            if let msg = systemMessage(title: "MCP Tool Progress", body: progress) {
                thread.messages.append(msg)
                thread.updatedAt = Date()
            }

        default:
            break
        }
    }

    private func extractString(_ dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = dict[key] as? String {
                return value
            }
            if let value = dict[key] as? NSNumber {
                return value.stringValue
            }
        }
        return nil
    }

    private func extractInt64(_ dict: [String: Any], keys: [String]) -> Int64? {
        for key in keys {
            if let value = extractInt64Value(dict[key]) {
                return value
            }
        }
        return nil
    }

    private func extractInt64Value(_ value: Any?) -> Int64? {
        switch value {
        case let value as Int64:
            return value
        case let value as Int:
            return Int64(value)
        case let value as Double:
            return Int64(value)
        case let value as NSNumber:
            return value.int64Value
        case let value as String:
            return Int64(value.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            return nil
        }
    }

    private func extractStringValue(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private func extractStringArray(_ dict: [String: Any], keys: [String]) -> [String] {
        for key in keys {
            guard let raw = dict[key] else { continue }
            if let strings = raw as? [String] {
                return strings.compactMap { sanitizedLineageId($0) }
            }
            if let values = raw as? [Any] {
                return values.compactMap { extractStringValue($0) }.compactMap { sanitizedLineageId($0) }
            }
        }
        return []
    }

    private func ingestCodexEventAgentMetadata(serverId: String, method: String, data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let params = root["params"] as? [String: Any] else { return }

        let eventPayload: [String: Any]
        let eventType: String
        if method == "codex/event" {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = extractString(eventPayload, keys: ["type"]) ?? "codex/event"
        } else {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = String(method.dropFirst("codex/event/".count))
        }

        func upsertIdentity(
            threadId: String?,
            agentId: String?,
            nickname: String?,
            role: String?,
            source: String
        ) {
            let normalizedThreadId = sanitizedLineageId(threadId)
            let normalizedAgentId = sanitizedLineageId(agentId)
            let normalizedNickname = sanitizedLineageId(nickname)
            let normalizedRole = sanitizedLineageId(role)
            guard normalizedThreadId != nil || normalizedAgentId != nil || normalizedNickname != nil || normalizedRole != nil else {
                return
            }
            upsertAgentDirectory(
                serverId: serverId,
                threadId: normalizedThreadId,
                agentId: normalizedAgentId,
                nickname: normalizedNickname,
                role: normalizedRole
            )
            debugAgentDirectoryLog(
                "codex-event metadata server=\(serverId) event=\(eventType) source=\(source) threadId=\(normalizedThreadId ?? "<nil>") agentId=\(normalizedAgentId ?? "<nil>") nickname=\(normalizedNickname ?? "<nil>") role=\(normalizedRole ?? "<nil>")"
            )
        }

        var senderMetadata = extractAgentMetadata(eventPayload)
        senderMetadata.threadId = senderMetadata.threadId
            ?? sanitizedLineageId(
                extractString(
                    eventPayload,
                    keys: ["sender_thread_id", "senderThreadId", "thread_id", "threadId", "conversation_id", "conversationId"]
                )
            )
            ?? sanitizedLineageId(
                extractString(
                    params,
                    keys: ["thread_id", "threadId", "conversation_id", "conversationId"]
                )
            )
        senderMetadata.agentId = senderMetadata.agentId
            ?? sanitizedLineageId(extractString(eventPayload, keys: ["sender_agent_id", "senderAgentId"]))
        upsertIdentity(
            threadId: senderMetadata.threadId,
            agentId: senderMetadata.agentId,
            nickname: senderMetadata.nickname,
            role: senderMetadata.role,
            source: "sender"
        )

        upsertIdentity(
            threadId: extractString(eventPayload, keys: ["new_thread_id", "newThreadId"]),
            agentId: extractString(eventPayload, keys: ["new_agent_id", "newAgentId"]),
            nickname: extractString(eventPayload, keys: ["new_agent_nickname", "newAgentNickname"]),
            role: extractString(eventPayload, keys: ["new_agent_role", "newAgentRole"]),
            source: "spawn-end"
        )

        upsertIdentity(
            threadId: extractString(eventPayload, keys: ["receiver_thread_id", "receiverThreadId"]),
            agentId: extractString(eventPayload, keys: ["receiver_agent_id", "receiverAgentId"]),
            nickname: extractString(eventPayload, keys: ["receiver_agent_nickname", "receiverAgentNickname"]),
            role: extractString(eventPayload, keys: ["receiver_agent_role", "receiverAgentRole"]),
            source: "receiver-single"
        )

        let receiverThreadIds = extractStringArray(
            eventPayload,
            keys: ["receiver_thread_ids", "receiverThreadIds"]
        )
        let receiverAgentsAny = (eventPayload["receiver_agents"] as? [Any]) ?? (eventPayload["receiverAgents"] as? [Any]) ?? []

        for (index, threadId) in receiverThreadIds.enumerated() {
            let alignedAgent = index < receiverAgentsAny.count ? (receiverAgentsAny[index] as? [String: Any]) : nil
            let alignedIdentity = alignedAgent.map { extractAgentMetadata($0) }
            upsertIdentity(
                threadId: threadId,
                agentId: alignedIdentity?.agentId ?? alignedAgent.flatMap { extractString($0, keys: ["agent_id", "agentId", "id"]) },
                nickname: alignedIdentity?.nickname ?? alignedAgent.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) },
                role: alignedIdentity?.role ?? alignedAgent.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]) },
                source: "receiver-thread-ids[\(index)]"
            )
        }

        for (index, rawReceiver) in receiverAgentsAny.enumerated() {
            if let receiver = rawReceiver as? [String: Any] {
                let metadata = extractAgentMetadata(receiver)
                let threadId = metadata.threadId
                    ?? extractString(receiver, keys: ["thread_id", "threadId", "receiver_thread_id", "receiverThreadId"])
                upsertIdentity(
                    threadId: threadId,
                    agentId: metadata.agentId,
                    nickname: metadata.nickname ?? extractString(receiver, keys: ["receiver_agent_nickname", "receiverAgentNickname"]),
                    role: metadata.role ?? extractString(receiver, keys: ["receiver_agent_role", "receiverAgentRole"]),
                    source: "receiver-agents[\(index)]"
                )
            } else {
                upsertIdentity(
                    threadId: extractStringValue(rawReceiver),
                    agentId: nil,
                    nickname: nil,
                    role: nil,
                    source: "receiver-agents[\(index)]-scalar"
                )
            }
        }

        if let statuses = eventPayload["statuses"] as? [String: Any] {
            for (threadId, rawStatus) in statuses {
                let statusDict = rawStatus as? [String: Any]
                upsertIdentity(
                    threadId: threadId,
                    agentId: statusDict.flatMap { extractString($0, keys: ["agent_id", "agentId"]) },
                    nickname: statusDict.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname"]) },
                    role: statusDict.flatMap { extractString($0, keys: ["agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType"]) },
                    source: "statuses"
                )
            }
        }

        if let statusEntries = eventPayload["agent_statuses"] as? [Any] {
            for (index, rawEntry) in statusEntries.enumerated() {
                guard let entry = rawEntry as? [String: Any] else { continue }
                upsertIdentity(
                    threadId: extractString(entry, keys: ["thread_id", "threadId", "receiver_thread_id", "receiverThreadId"]),
                    agentId: extractString(entry, keys: ["agent_id", "agentId"]),
                    nickname: extractString(entry, keys: ["agent_nickname", "agentNickname", "receiver_agent_nickname", "receiverAgentNickname"]),
                    role: extractString(entry, keys: ["agent_role", "agentRole", "receiver_agent_role", "receiverAgentRole", "agent_type", "agentType"]),
                    source: "agent-statuses[\(index)]"
                )
            }
        }
    }

    private struct AgentIdentity {
        var threadId: String?
        var agentId: String?
        var nickname: String?
        var role: String?

        var hasMetadata: Bool {
            agentId != nil || nickname != nil || role != nil
        }
    }

    private func extractAgentMetadata(_ dict: [String: Any]) -> AgentIdentity {
        let directThreadId = extractString(dict, keys: [
            "threadId", "thread_id",
            "conversationId", "conversation_id",
            "receiverThreadId", "receiver_thread_id"
        ])
        let directAgentId = extractString(dict, keys: ["agentId", "agent_id", "id"])
        let directNickname = extractString(dict, keys: ["agentNickname", "agent_nickname", "nickname", "name"])
        let directRole = extractString(dict, keys: ["agentRole", "agent_role", "agentType", "agent_type", "role", "type"])

        let source = dict["source"] as? [String: Any]
        let subAgent = (source?["subAgent"] as? [String: Any]) ?? (source?["sub_agent"] as? [String: Any])
        let threadSpawn = (subAgent?["thread_spawn"] as? [String: Any]) ?? (subAgent?["threadSpawn"] as? [String: Any])
        let nestedThreadId = threadSpawn.flatMap { extractString($0, keys: ["thread_id", "threadId"]) }
        let nestedAgentId = threadSpawn.flatMap { extractString($0, keys: ["agent_id", "agentId"]) }
        let nestedSpawnId = threadSpawn.flatMap { extractString($0, keys: ["id"]) }
        let nestedSubAgentId = subAgent.flatMap { extractString($0, keys: ["agent_id", "agentId", "id"]) }
        let nestedNickname = threadSpawn.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) }
        let nestedRole = threadSpawn.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]) }
        let nestedSubAgentNickname = subAgent.flatMap { extractString($0, keys: ["agent_nickname", "agentNickname", "nickname", "name"]) }
        let nestedSubAgentRole = subAgent.flatMap { extractString($0, keys: ["agent_role", "agentRole", "agent_type", "agentType", "role", "type"]) }

        return AgentIdentity(
            threadId: sanitizedLineageId(directThreadId) ?? sanitizedLineageId(nestedThreadId),
            agentId: sanitizedLineageId(directAgentId)
                ?? sanitizedLineageId(nestedAgentId)
                ?? sanitizedLineageId(nestedSubAgentId)
                ?? sanitizedLineageId(nestedSpawnId),
            nickname: sanitizedLineageId(directNickname)
                ?? sanitizedLineageId(nestedNickname)
                ?? sanitizedLineageId(nestedSubAgentNickname),
            role: sanitizedLineageId(directRole)
                ?? sanitizedLineageId(nestedRole)
                ?? sanitizedLineageId(nestedSubAgentRole)
        )
    }

    private func resolveAgentIdentity(
        serverId: String,
        threadId: String?,
        params: [String: Any] = [:]
    ) -> AgentIdentity {
        let normalizedThreadId = sanitizedLineageId(threadId)
        var fromParams = extractAgentMetadata(params)
        fromParams.threadId = fromParams.threadId ?? normalizedThreadId

        if fromParams.hasMetadata {
            upsertAgentDirectory(
                serverId: serverId,
                threadId: fromParams.threadId,
                agentId: fromParams.agentId,
                nickname: fromParams.nickname,
                role: fromParams.role
            )
        }

        let fromDirectory = mergedAgentDirectoryEntry(
            serverId: serverId,
            threadId: fromParams.threadId,
            agentId: fromParams.agentId
        )
        let resolvedThreadId = fromParams.threadId ?? fromDirectory?.threadId
        let fromThreadState = resolvedThreadId
            .map { ThreadKey(serverId: serverId, threadId: $0) }
            .flatMap { threads[$0] }

        let resolved = AgentIdentity(
            threadId: resolvedThreadId,
            agentId: fromParams.agentId ?? fromDirectory?.agentId,
            nickname: fromParams.nickname ?? fromDirectory?.nickname ?? fromThreadState?.agentNickname,
            role: fromParams.role ?? fromDirectory?.role ?? fromThreadState?.agentRole
        )

        if resolved.hasMetadata {
            upsertAgentDirectory(
                serverId: serverId,
                threadId: resolved.threadId,
                agentId: resolved.agentId,
                nickname: resolved.nickname,
                role: resolved.role
            )
        }
        return resolved
    }

    private func mergedAgentDirectoryEntry(serverId: String?, threadId: String?, agentId: String?) -> AgentDirectoryEntry? {
        guard let serverScope = agentDirectoryServerScope(serverId) else {
            return nil
        }
        let normalizedThreadId = sanitizedLineageId(threadId)
        let normalizedAgentId = sanitizedLineageId(agentId)
        let threadEntry = normalizedThreadId.flatMap {
            agentDirectory.byThreadId[agentDirectoryScopedKey(serverId: serverScope, id: $0)]
        }
        let agentEntry = normalizedAgentId.flatMap {
            agentDirectory.byAgentId[agentDirectoryScopedKey(serverId: serverScope, id: $0)]
        }
        guard threadEntry != nil || agentEntry != nil else { return nil }

        let preferred = agentEntry ?? threadEntry
        return AgentDirectoryEntry(
            nickname: preferred?.nickname ?? threadEntry?.nickname ?? agentEntry?.nickname,
            role: preferred?.role ?? threadEntry?.role ?? agentEntry?.role,
            threadId: normalizedThreadId ?? threadEntry?.threadId ?? agentEntry?.threadId,
            agentId: normalizedAgentId ?? agentEntry?.agentId ?? threadEntry?.agentId
        )
    }

    private func upsertAgentDirectory(
        serverId: String?,
        threadId: String?,
        agentId: String?,
        nickname: String?,
        role: String?
    ) {
        guard let serverScope = agentDirectoryServerScope(serverId) else {
            debugAgentDirectoryLog(
                "upsert skipped threadId=\(threadId ?? "<nil>") agentId=\(agentId ?? "<nil>") reason=missing-server-scope"
            )
            return
        }
        let normalizedThreadId = sanitizedLineageId(threadId)
        let normalizedAgentId = sanitizedLineageId(agentId)
        let normalizedNickname = sanitizedLineageId(nickname)
        let normalizedRole = sanitizedLineageId(role)
        guard normalizedThreadId != nil || normalizedAgentId != nil || normalizedNickname != nil || normalizedRole != nil else {
            debugAgentDirectoryLog(
                "upsert skipped server=\(serverScope) threadId=\(threadId ?? "<nil>") agentId=\(agentId ?? "<nil>") reason=empty-identifiers-and-metadata"
            )
            return
        }

        let scopedThreadKey = normalizedThreadId.map { agentDirectoryScopedKey(serverId: serverScope, id: $0) }
        let scopedAgentKey = normalizedAgentId.map { agentDirectoryScopedKey(serverId: serverScope, id: $0) }

        var merged = AgentDirectoryEntry(
            nickname: normalizedNickname,
            role: normalizedRole,
            threadId: normalizedThreadId,
            agentId: normalizedAgentId
        )

        if let scopedThreadKey, let existing = agentDirectory.byThreadId[scopedThreadKey] {
            merged = merged.merged(over: existing)
        }
        if let scopedAgentKey, let existing = agentDirectory.byAgentId[scopedAgentKey] {
            merged = merged.merged(over: existing)
        }

        var didChange = false
        if let scopedThreadKey, agentDirectory.byThreadId[scopedThreadKey] != merged {
            agentDirectory.byThreadId[scopedThreadKey] = merged
            didChange = true
        }
        if let scopedAgentKey, agentDirectory.byAgentId[scopedAgentKey] != merged {
            agentDirectory.byAgentId[scopedAgentKey] = merged
            didChange = true
        }
        if let linkedThreadId = merged.threadId,
           let linkedAgentId = merged.agentId {
            let linkedThreadKey = agentDirectoryScopedKey(serverId: serverScope, id: linkedThreadId)
            let linkedAgentKey = agentDirectoryScopedKey(serverId: serverScope, id: linkedAgentId)
            if agentDirectory.byThreadId[linkedThreadKey] != merged {
                agentDirectory.byThreadId[linkedThreadKey] = merged
                didChange = true
            }
            if agentDirectory.byAgentId[linkedAgentKey] != merged {
                agentDirectory.byAgentId[linkedAgentKey] = merged
                didChange = true
            }
        }
        let mergedLabel = formatAgentLabel(
            nickname: merged.nickname,
            role: merged.role,
            fallbackThreadId: merged.threadId ?? merged.agentId
        ) ?? "<nil>"
        if didChange {
            agentDirectoryVersion = agentDirectoryVersion &+ 1
            debugAgentDirectoryLog(
                "upsert updated server=\(serverScope) threadId=\(merged.threadId ?? "<nil>") agentId=\(merged.agentId ?? "<nil>") label=\(mergedLabel)"
            )
        } else if merged.nickname != nil || merged.role != nil || merged.agentId != nil {
            debugAgentDirectoryLog(
                "upsert no-op server=\(serverScope) threadId=\(merged.threadId ?? "<nil>") agentId=\(merged.agentId ?? "<nil>") label=\(mergedLabel)"
            )
        }
    }

    private func formatAgentLabel(nickname: String?, role: String?, fallbackThreadId: String? = nil) -> String? {
        AgentLabelFormatter.format(
            nickname: nickname,
            role: role,
            fallbackIdentifier: fallbackThreadId
        )
    }

    private func sanitizedLineageId(_ raw: String?) -> String? {
        AgentLabelFormatter.sanitized(raw)
    }

    private func upsertLiveItemMessage(_ message: ChatMessage, itemId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveItemMessageIndices[key]?[itemId],
           thread.messages.indices.contains(index) {
            thread.messages[index] = message
        } else {
            let index = thread.messages.count
            thread.messages.append(message)
            liveItemMessageIndices[key, default: [:]][itemId] = index
        }
    }

    private func completeLiveItemMessage(_ message: ChatMessage, itemId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveItemMessageIndices[key]?[itemId],
           thread.messages.indices.contains(index) {
            thread.messages[index] = message
        } else {
            thread.messages.append(message)
        }
        liveItemMessageIndices[key]?[itemId] = nil
    }

    private func appendCommandOutputDelta(_ delta: String, itemId: String, key: ThreadKey, thread: ThreadState) -> Bool {
        guard let index = liveItemMessageIndices[key]?[itemId],
              thread.messages.indices.contains(index) else {
            return false
        }
        thread.messages[index].text = mergeCommandOutput(thread.messages[index].text, delta: delta)
        return true
    }

    private func appendMcpProgress(_ progress: String, itemId: String, key: ThreadKey, thread: ThreadState) -> Bool {
        guard let index = liveItemMessageIndices[key]?[itemId],
              thread.messages.indices.contains(index) else {
            return false
        }
        thread.messages[index].text = mergeProgress(thread.messages[index].text, progress: progress)
        return true
    }

    private func mergeCommandOutput(_ current: String, delta: String) -> String {
        let outputPrefix = "\n\nOutput:\n```text\n"
        let closingFence = "\n```"

        if let outputRange = current.range(of: outputPrefix),
           let closeRange = current.range(of: closingFence, options: .backwards),
           closeRange.lowerBound >= outputRange.upperBound {
            var updated = current
            updated.insert(contentsOf: delta, at: closeRange.lowerBound)
            return updated
        }

        var chunk = delta
        if !chunk.hasSuffix("\n") {
            chunk += "\n"
        }
        return current + outputPrefix + chunk + "```"
    }

    private func mergeProgress(_ current: String, progress: String) -> String {
        if current.contains("\n\nProgress:\n") {
            return current + "\n" + progress
        }
        return current + "\n\nProgress:\n" + progress
    }

    private func handleTurnDiffNotification(serverId: String, data: Data) {
        struct TurnDiffParams: Decodable {
            let threadId: String?
            let turnId: String?
            let diff: String?
        }
        struct TurnDiffNotification: Decodable { let params: TurnDiffParams }
        guard let notif = try? JSONDecoder().decode(TurnDiffNotification.self, from: data),
              let diff = notif.params.diff?.trimmingCharacters(in: .whitespacesAndNewlines),
              !diff.isEmpty else { return }

        let key = resolveThreadKey(serverId: serverId, threadId: notif.params.threadId)

        // Count changed files for LA
        let diffHeaders = diff.components(separatedBy: "diff --git ").count - 1
        let fileChangeCount = max(diffHeaders, 1)
        liveActivityFileChangeCounts[key] = fileChangeCount

        guard let thread = threads[key],
              let msg = systemMessage(title: "File Diff", body: "```diff\n\(diff)\n```") else { return }

        if let turnId = notif.params.turnId, !turnId.isEmpty {
            upsertLiveTurnDiffMessage(msg, turnId: turnId, key: key, thread: thread)
        } else {
            thread.messages.append(msg)
        }
        thread.updatedAt = Date()
    }

    private func upsertLiveTurnDiffMessage(_ message: ChatMessage, turnId: String, key: ThreadKey, thread: ThreadState) {
        if let index = liveTurnDiffMessageIndices[key]?[turnId],
           thread.messages.indices.contains(index) {
            thread.messages[index] = message
        } else {
            let index = thread.messages.count
            thread.messages.append(message)
            liveTurnDiffMessageIndices[key, default: [:]][turnId] = index
        }
    }

    private func handleLegacyCodexEventNotification(serverId: String, method: String, data: Data) {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let params = root["params"] as? [String: Any] else { return }

        let eventPayload: [String: Any]
        let eventType: String

        if method == "codex/event" {
            guard let msg = params["msg"] as? [String: Any] else { return }
            eventPayload = msg
            eventType = extractString(msg, keys: ["type"]) ?? ""
        } else {
            eventPayload = (params["msg"] as? [String: Any]) ?? params
            eventType = String(method.dropFirst("codex/event/".count))
        }

        guard !eventType.isEmpty else { return }

        let threadId = extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
            ?? extractString(eventPayload, keys: ["threadId", "thread_id", "conversationId", "conversation_id"])
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }

        switch eventType {
        case "exec_command_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let command = extractCommandText(eventPayload)
            let cwd = extractString(eventPayload, keys: ["cwd"]) ?? ""

            updateLiveActivity(key: key, phase: .toolCall, toolName: command.isEmpty ? "shell" : command)

            var lines: [String] = ["Status: inProgress"]
            if !cwd.isEmpty { lines.append("Directory: \(cwd)") }
            var body = lines.joined(separator: "\n")
            if !command.isEmpty { body += "\n\nCommand:\n```bash\n\(command)\n```" }

            guard let msg = systemMessage(title: "Command Execution", body: body) else { return }
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "exec_command_output_delta":
            guard let delta = extractString(eventPayload, keys: ["chunk"]), !delta.isEmpty else { return }
            if let itemId = extractString(eventPayload, keys: ["call_id", "callId"]),
               appendCommandOutputDelta(delta, itemId: itemId, key: key, thread: thread) {
                thread.updatedAt = Date()
                return
            }
            if let msg = systemMessage(title: "Command Output", body: "```text\n\(delta)\n```") {
                thread.messages.append(msg)
                thread.updatedAt = Date()
            }

        case "exec_command_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let command = extractCommandText(eventPayload)
            let cwd = extractString(eventPayload, keys: ["cwd"]) ?? ""
            let status = extractString(eventPayload, keys: ["status"]) ?? "completed"
            let exitCode = extractString(eventPayload, keys: ["exit_code", "exitCode"])
            let durationMs = durationMillis(from: eventPayload["duration"])

            var lines: [String] = ["Status: \(status)"]
            if !cwd.isEmpty { lines.append("Directory: \(cwd)") }
            if let exitCode, !exitCode.isEmpty { lines.append("Exit code: \(exitCode)") }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }

            var body = lines.joined(separator: "\n")
            if !command.isEmpty { body += "\n\nCommand:\n```bash\n\(command)\n```" }

            let output = extractCommandOutput(eventPayload)
            if !output.isEmpty {
                body += "\n\nOutput:\n```text\n\(output)\n```"
            }

            guard let msg = systemMessage(title: "Command Execution", body: body) else { return }
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "mcp_tool_call_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let invocation = eventPayload["invocation"] as? [String: Any]
            let server = invocation.flatMap { extractString($0, keys: ["server"]) } ?? ""
            let tool = invocation.flatMap { extractString($0, keys: ["tool"]) } ?? ""

            var lines: [String] = ["Status: inProgress"]
            if !server.isEmpty || !tool.isEmpty {
                lines.append("Tool: \(server.isEmpty ? tool : "\(server)/\(tool)")")
            }
            var body = lines.joined(separator: "\n")
            if let args = invocation?["arguments"], let pretty = prettyJSON(args) {
                body += "\n\nArguments:\n```json\n\(pretty)\n```"
            }

            guard let msg = systemMessage(title: "MCP Tool Call", body: body) else { return }
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "mcp_tool_call_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let invocation = eventPayload["invocation"] as? [String: Any]
            let server = invocation.flatMap { extractString($0, keys: ["server"]) } ?? ""
            let tool = invocation.flatMap { extractString($0, keys: ["tool"]) } ?? ""
            let durationMs = durationMillis(from: eventPayload["duration"])
            let result = eventPayload["result"]

            var status = "completed"
            if let resultDict = result as? [String: Any], resultDict["Err"] != nil {
                status = "failed"
            }

            var lines: [String] = ["Status: \(status)"]
            if !server.isEmpty || !tool.isEmpty {
                lines.append("Tool: \(server.isEmpty ? tool : "\(server)/\(tool)")")
            }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            var body = lines.joined(separator: "\n")

            if let result, let pretty = prettyJSON(result) {
                body += "\n\nResult:\n```json\n\(pretty)\n```"
            }

            guard let msg = systemMessage(title: "MCP Tool Call", body: body) else { return }
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "web_search_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId", "item_id", "itemId"])
            let query = extractString(eventPayload, keys: ["query"]) ?? ""

            var lines: [String] = ["Status: inProgress"]
            if !query.isEmpty { lines.append("Query: \(query)") }
            let body = lines.joined(separator: "\n")

            guard let msg = systemMessage(title: "Web Search", body: body) else { return }
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "web_search_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId", "item_id", "itemId"])
            let query = extractString(eventPayload, keys: ["query"]) ?? ""
            let status = extractString(eventPayload, keys: ["status"]) ?? "completed"

            var lines: [String] = ["Status: \(status)"]
            if !query.isEmpty { lines.append("Query: \(query)") }
            var body = lines.joined(separator: "\n")
            if let action = eventPayload["action"], let pretty = prettyJSON(action) {
                body += "\n\nAction:\n```json\n\(pretty)\n```"
            }

            guard let msg = systemMessage(title: "Web Search", body: body) else { return }
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "patch_apply_begin":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let changeSummary = legacyPatchChangeBody(from: eventPayload["changes"])
            let autoApproved = (eventPayload["auto_approved"] as? Bool) == true

            var body = "Status: inProgress"
            body += "\nApproval: \(autoApproved ? "auto" : "requested")"
            if !changeSummary.isEmpty {
                body += "\n\n" + changeSummary
            }

            guard let msg = systemMessage(title: "File Change", body: body) else { return }
            if let itemId {
                upsertLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "patch_apply_end":
            let itemId = extractString(eventPayload, keys: ["call_id", "callId"])
            let status = extractString(eventPayload, keys: ["status"]) ?? ((eventPayload["success"] as? Bool) == true ? "completed" : "failed")
            let stdout = extractString(eventPayload, keys: ["stdout"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = extractString(eventPayload, keys: ["stderr"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let changeSummary = legacyPatchChangeBody(from: eventPayload["changes"])

            var body = "Status: \(status)"
            if !changeSummary.isEmpty {
                body += "\n\n" + changeSummary
            }
            if !stdout.isEmpty {
                body += "\n\nOutput:\n```text\n\(stdout)\n```"
            }
            if !stderr.isEmpty {
                body += "\n\nError:\n```text\n\(stderr)\n```"
            }

            guard let msg = systemMessage(title: "File Change", body: body) else { return }
            if let itemId {
                completeLiveItemMessage(msg, itemId: itemId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        case "turn_diff":
            let turnId = extractString(params, keys: ["id", "turnId", "turn_id"])
                ?? extractString(eventPayload, keys: ["id", "turnId", "turn_id"])
            guard let diff = extractString(eventPayload, keys: ["unified_diff"])?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !diff.isEmpty,
                  let msg = systemMessage(title: "File Diff", body: "```diff\n\(diff)\n```") else { return }

            if let turnId, !turnId.isEmpty {
                upsertLiveTurnDiffMessage(msg, turnId: turnId, key: key, thread: thread)
            } else {
                thread.messages.append(msg)
            }
            thread.updatedAt = Date()

        default:
            break
        }
    }

    private func extractCommandText(_ eventPayload: [String: Any]) -> String {
        if let parts = eventPayload["command"] as? [String], !parts.isEmpty {
            return parts.joined(separator: " ")
        }
        return extractString(eventPayload, keys: ["command"]) ?? ""
    }

    private func extractCommandOutput(_ eventPayload: [String: Any]) -> String {
        let candidateKeys = ["aggregated_output", "formatted_output", "stdout", "stderr"]
        let chunks = candidateKeys.compactMap { extractString(eventPayload, keys: [$0]) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return chunks.joined(separator: "\n")
    }

    private func durationMillis(from rawDuration: Any?) -> Int? {
        if let value = rawDuration as? NSNumber {
            return value.intValue
        }
        if let dict = rawDuration as? [String: Any],
           let secsValue = dict["secs"] as? NSNumber {
            let nanosValue = (dict["nanos"] as? NSNumber)?.int64Value ?? 0
            let millis = secsValue.int64Value * 1_000 + nanosValue / 1_000_000
            return Int(millis)
        }
        return nil
    }

    private func legacyPatchChangeBody(from rawChanges: Any?) -> String {
        guard let changes = rawChanges as? [String: Any], !changes.isEmpty else { return "" }
        var sections: [String] = []
        for path in changes.keys.sorted() {
            guard let change = changes[path] as? [String: Any] else { continue }
            let kind = extractString(change, keys: ["type"]) ?? "update"
            var section = "Path: \(path)\nKind: \(kind)"
            if kind == "update",
               let diff = extractString(change, keys: ["unified_diff"]),
               !diff.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section += "\n\n```diff\n\(diff)\n```"
            } else if (kind == "add" || kind == "delete"),
                      let content = extractString(change, keys: ["content"]),
                      !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                section += "\n\n```text\n\(content)\n```"
            }
            sections.append(section)
        }
        return sections.joined(separator: "\n\n---\n\n")
    }

    private func extractThreadId(from data: Data) -> String? {
        struct Wrapper: Decodable {
            struct Params: Decodable {
                let threadId: String?
                let conversationId: String?
            }
            let params: Params?
        }
        guard let params = (try? JSONDecoder().decode(Wrapper.self, from: data))?.params else { return nil }
        return params.threadId ?? params.conversationId
    }

    private func extractTurnId(from data: Data) -> String? {
        struct Wrapper: Decodable {
            struct Params: Decodable {
                struct Turn: Decodable { let id: String? }
                let turn: Turn?
                let turnId: String?
            }
            let params: Params?
        }
        guard let params = (try? JSONDecoder().decode(Wrapper.self, from: data))?.params else { return nil }
        return params.turn?.id ?? params.turnId
    }

    func syncActiveThreadFromServer() async {
        guard let key = activeThreadKey else { return }
        await syncThreadFromServer(key)
    }

    private func syncThreadFromServer(_ key: ThreadKey, force: Bool = false) async {
        guard let conn = connections[key.serverId], conn.isConnected,
              let thread = threads[key] else {
            if force {
                NSLog("[%@ sync] bail: server %@ connected=%d thread=%d", ts, key.serverId, connections[key.serverId]?.isConnected == true ? 1 : 0, threads[key] != nil ? 1 : 0)
                // Can't reach server — reset stuck thinking state so UI isn't frozen
                if let thread = threads[key], thread.hasTurnActive {
                    NSLog("[%@ sync] resetting %@ to ready (can't reach server)", ts, key.threadId)
                    thread.status = .ready
                    thread.activeTurnId = nil
                }
            }
            return
        }
        let wasActive = thread.hasTurnActive
        if !force && wasActive { return }

        let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd
        if force { NSLog("[%@ sync] resumeThread %@ (wasActive=%d)", ts, key.threadId, wasActive ? 1 : 0) }
        guard let response = try? await conn.resumeThread(
            threadId: key.threadId,
            cwd: cwd,
            approvalPolicy: "never",
            sandboxMode: "workspace-write"
        ) else {
            if force {
                NSLog("[%@ sync] resumeThread FAILED for %@, resetting to ready", ts, key.threadId)
                if wasActive {
                    thread.status = .ready
                    thread.activeTurnId = nil
                }
            }
            return
        }
        if force { NSLog("[%@ sync] resumeThread OK for %@, turns=%d", ts, key.threadId, response.thread.turns.count) }

        // resumeThread re-subscribes to events. If a turn is still active,
        // the server will keep sending notifications. Don't reset status.
        if force {
            NSLog("[%@ sync] after resume: wasActive=%d hasTurnActive=%d", ts, wasActive ? 1 : 0, thread.hasTurnActive ? 1 : 0)
        }

        var restored = restoredMessages(
            from: response.thread.turns,
            serverId: key.serverId,
            defaultAgentNickname: response.thread.agentNickname ?? thread.agentNickname,
            defaultAgentRole: response.thread.agentRole ?? thread.agentRole
        )

        // Suspend forwarding during batch update to avoid N separate objectWillChange publishes
        threadSubscriptions[key]?.cancel()

        thread.cwd = response.cwd
        thread.model = response.model
        thread.modelProvider = response.modelProvider ?? response.model
        thread.reasoningEffort = response.reasoningEffort ?? thread.reasoningEffort
        thread.rolloutPath = response.thread.path ?? thread.rolloutPath
        thread.parentThreadId = sanitizedLineageId(response.thread.parentThreadId) ?? thread.parentThreadId
        thread.rootThreadId = sanitizedLineageId(response.thread.rootThreadId) ?? thread.rootThreadId
        thread.agentNickname = sanitizedLineageId(response.thread.agentNickname) ?? thread.agentNickname
        thread.agentRole = sanitizedLineageId(response.thread.agentRole) ?? thread.agentRole
        await refreshThreadContextWindow(for: key, cwd: response.cwd)
        await refreshPersistedContextUsage(for: key)

        let needsMessageUpdate: Bool
        if messagesEquivalent(thread.messages, restored) {
            needsMessageUpdate = false
        } else if shouldPreferLocalMessages(current: thread.messages, restored: restored) {
            needsMessageUpdate = false
        } else {
            // Preserve IDs from matching existing messages so SwiftUI doesn't destroy/recreate cells
            let existing = thread.messages
            for i in restored.indices {
                if i < existing.count,
                   existing[i].role == restored[i].role,
                   existing[i].text == restored[i].text {
                    restored[i].id = existing[i].id
                    if restored[i].widgetState == nil, existing[i].widgetState != nil {
                        restored[i].widgetState = existing[i].widgetState
                    }
                }
            }
            thread.messages = restored
            needsMessageUpdate = true
        }

        if needsMessageUpdate {
            threadTurnCounts[key] = response.thread.turns.count
        }

        // Reconnect forwarding and send a single publish
        observeThread(thread)
        objectWillChange.send()
        upsertAgentDirectory(
            serverId: key.serverId,
            threadId: response.thread.id,
            agentId: response.thread.agentId,
            nickname: thread.agentNickname,
            role: thread.agentRole
        )
        thread.updatedAt = Date()
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
    }

    private func refreshThreadContextWindow(for key: ThreadKey, cwd: String) async {
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty,
              let conn = connections[key.serverId],
              conn.isConnected,
              let response = try? await conn.readConfig(cwd: normalizedCwd),
              let config = response.config.value as? [String: Any],
              let modelContextWindow = extractInt64(config, keys: ["model_context_window", "modelContextWindow"]),
              let thread = threads[key] else {
            return
        }

        thread.modelContextWindow = modelContextWindow
    }

    private func refreshPersistedContextUsage(for key: ThreadKey) async {
        guard let thread = threads[key],
              let conn = connections[key.serverId],
              conn.isConnected,
              conn.server.source != .local else {
            return
        }

        let rolloutPath = thread.rolloutPath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rolloutPath.isEmpty else { return }

        let rolloutDirectory = URL(fileURLWithPath: rolloutPath).deletingLastPathComponent().path
        let shellScript = """
        line=$(awk '/"type":"token_count","info":\\{/{line=$0} END { if (line) print line }' "$1")
        [ -n "$line" ] || exit 0
        context=$(printf '%s\n' "$line" | sed -nE 's/.*"last_token_usage":\\{[^}]*"total_tokens":([0-9]+).*/\\1/p')
        if [ -z "$context" ]; then
            context=$(printf '%s\n' "$line" | sed -nE 's/.*"total_token_usage":\\{[^}]*"total_tokens":([0-9]+).*/\\1/p')
        fi
        window=$(printf '%s\n' "$line" | sed -nE 's/.*"model_context_window":([0-9]+).*/\\1/p')
        [ -n "$context$window" ] || exit 0
        printf '{"contextTokens":%s,"modelContextWindow":%s}\n' "${context:-null}" "${window:-null}"
        """

        guard let response = try? await conn.execCommand(
            ["/bin/sh", "-c", shellScript, "litter-rollout-usage", rolloutPath],
            cwd: rolloutDirectory
        ),
        response.exitCode == 0 else {
            return
        }

        let stdout = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stdout.isEmpty,
              let data = stdout.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(PersistedContextUsageSnapshot.self, from: data) else {
            return
        }

        if let modelContextWindow = snapshot.modelContextWindow {
            thread.modelContextWindow = modelContextWindow
        }
        if let contextTokens = snapshot.contextTokens {
            thread.contextTokensUsed = contextTokens
        }
    }

    private func rollbackDepthForMessage(_ message: ChatMessage, in key: ThreadKey) throws -> Int {
        guard let selectedTurnIndex = message.sourceTurnIndex else {
            throw NSError(domain: "Litter", code: 1021, userInfo: [NSLocalizedDescriptionKey: "Message is missing turn metadata"])
        }
        let totalTurns = threadTurnCounts[key] ?? inferredTurnCount(from: threads[key]?.messages ?? [])
        guard totalTurns > 0 else {
            throw NSError(domain: "Litter", code: 1022, userInfo: [NSLocalizedDescriptionKey: "No turn history available"])
        }
        guard selectedTurnIndex >= 0, selectedTurnIndex < totalTurns else {
            throw NSError(domain: "Litter", code: 1023, userInfo: [NSLocalizedDescriptionKey: "Message is outside available turn history"])
        }
        return max(totalTurns - selectedTurnIndex - 1, 0)
    }

    private func inferredTurnCount(from messages: [ChatMessage]) -> Int {
        if let maxTurnIndex = messages.compactMap(\.sourceTurnIndex).max() {
            return maxTurnIndex + 1
        }
        return messages.filter { $0.role == .user && $0.isFromUserTurnBoundary }.count
    }

    private func shouldPreferLocalMessages(current: [ChatMessage], restored: [ChatMessage]) -> Bool {
        // Protect against transient/stale resume snapshots that can briefly
        // return fewer messages and cause the UI to "clear then refill".
        if !current.isEmpty && restored.isEmpty {
            return true
        }
        if restored.count < current.count {
            return true
        }

        let currentToolCount = current.filter(isToolSystemMessage).count
        let restoredToolCount = restored.filter(isToolSystemMessage).count
        return currentToolCount > restoredToolCount && restored.count <= current.count
    }

    private func isToolSystemMessage(_ message: ChatMessage) -> Bool {
        guard message.role == .system else { return false }
        guard let title = systemTitle(from: message.text)?.lowercased() else { return false }
        return title.contains("command")
            || title.contains("file")
            || title.contains("mcp")
            || title.contains("web")
            || title.contains("collab")
            || title.contains("image")
    }

    private func systemTitle(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return nil }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        let title = firstLine.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }

    private func messagesEquivalent(_ lhs: [ChatMessage], _ rhs: [ChatMessage]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        for (left, right) in zip(lhs, rhs) {
            guard left.role == right.role, left.text == right.text else { return false }
            guard left.sourceTurnId == right.sourceTurnId else { return false }
            guard left.sourceTurnIndex == right.sourceTurnIndex else { return false }
            guard left.isFromUserTurnBoundary == right.isFromUserTurnBoundary else { return false }
            guard left.agentNickname == right.agentNickname else { return false }
            guard left.agentRole == right.agentRole else { return false }
            guard left.images.count == right.images.count else { return false }
            for (leftImage, rightImage) in zip(left.images, right.images) {
                guard leftImage.data == rightImage.data else { return false }
            }
        }
        return true
    }

    private func resolveThreadKey(serverId: String, threadId: String?) -> ThreadKey {
        if let threadId {
            return ThreadKey(serverId: serverId, threadId: threadId)
        }
        if let active = activeThreadKey, active.serverId == serverId {
            return active
        }
        return threads.values
            .first { $0.serverId == serverId && $0.hasTurnActive }?
            .key ?? ThreadKey(serverId: serverId, threadId: "")
    }

    // MARK: - Background / Foreground Lifecycle

    func appDidEnterBackground() {
        let activeTurnKeys = threads.compactMap { (key, thread) -> ThreadKey? in
            thread.hasTurnActive ? key : nil
        }
        NSLog("[%@ bg] entering background, activeTurnKeys=%d liveActivities=%d", ts, activeTurnKeys.count, liveActivities.count)

        guard !activeTurnKeys.isEmpty else { return }
        backgroundedTurnKeys = Set(activeTurnKeys)
        bgWakeCount = 0

        for key in activeTurnKeys {
            if liveActivities[key] == nil, let thread = threads[key] {
                startLiveActivity(key: key, model: thread.model, cwd: thread.cwd, prompt: thread.preview ?? "")
            }
        }

        registerPushProxy()

        var bgID = UIBackgroundTaskIdentifier.invalid
        bgID = UIApplication.shared.beginBackgroundTask {
            NSLog("[bg] background task expiring")
            UIApplication.shared.endBackgroundTask(bgID)
        }
        backgroundTaskID = bgID
    }

    private func registerPushProxy() {
        guard let tokenData = devicePushToken else {
            NSLog("[%@ push] no device push token, skipping proxy register", ts)
            return
        }
        guard pushProxyRegistrationId == nil else { return }
        let token = tokenData.map { String(format: "%02x", $0) }.joined()
        Task {
            do {
                let regId = try await pushProxy.register(pushToken: token, interval: 30, ttl: 7200)
                pushProxyRegistrationId = regId
                NSLog("[%@ push] registered → %@", ts, regId)
            } catch {
                NSLog("[%@ push] register failed: %@", ts, error.localizedDescription)
            }
        }
    }

    private func deregisterPushProxy() {
        guard let regId = pushProxyRegistrationId else { return }
        pushProxyRegistrationId = nil
        Task { try? await pushProxy.deregister(registrationId: regId) }
    }

    func appDidBecomeActive() {
        NSLog("[%@ bg] becoming active, backgroundedTurnKeys=%d liveActivities=%d bgWakes=%d", ts, backgroundedTurnKeys.count, liveActivities.count, bgWakeCount)
        deregisterPushProxy()
        endBackgroundTaskIfNeeded()

        let keysToSync = backgroundedTurnKeys.union(
            threads.compactMap { $0.value.hasTurnActive ? $0.key : nil }
        )
        backgroundedTurnKeys.removeAll()

        Task {
            for (serverId, conn) in connections {
                NSLog("[%@ bg] reconnecting server %@", ts, serverId)
                conn.disconnect()
                await conn.connect()
            }

            // First pass: read-only sync to get clean state without event subscription
            for key in keysToSync {
                guard let conn = connections[key.serverId], conn.isConnected,
                      let thread = threads[key] else { continue }
                if let response = try? await conn.readThread(threadId: key.threadId) {
                    let restored = restoredMessages(
                        from: response.thread.turns,
                        serverId: key.serverId,
                        defaultAgentNickname: response.thread.agentNickname ?? thread.agentNickname,
                        defaultAgentRole: response.thread.agentRole ?? thread.agentRole
                    )
                    thread.messages = restored
                    if let model = response.model { thread.model = model }
                    if let cwd = response.cwd { thread.cwd = cwd }
                    let turnDone = response.thread.turns.last?.status == "completed"
                        || response.thread.turns.last?.status == "failed"
                        || response.thread.turns.last?.status == "interrupted"
                    if turnDone {
                        thread.status = .ready
                        thread.activeTurnId = nil
                    }
                    NSLog("[%@ bg] read %@ msgs=%d lastStatus=%@", ts, key.threadId, restored.count, response.thread.turns.last?.status ?? "nil")
                }
            }

            // Second pass: resume threads that are still active to get live updates
            suppressNotifications = true
            for key in keysToSync where threads[key]?.hasTurnActive == true {
                await syncThreadFromServer(key, force: true)
            }
            if let activeKey = activeThreadKey, !keysToSync.contains(activeKey) {
                await syncThreadFromServer(activeKey, force: true)
            }
            suppressNotifications = false

            for key in liveActivities.keys {
                if threads[key]?.hasTurnActive != true {
                    endLiveActivity(key: key, phase: .completed)
                }
            }
        }
    }

    func handleBackgroundPush() async {
        bgWakeCount += 1
        let keys = backgroundedTurnKeys
        NSLog("[%@ push-wake] #%d keys=%d", ts, bgWakeCount, keys.count)
        guard !keys.isEmpty else { return }

        let serverIds = Set(keys.map(\.serverId))
        for serverId in serverIds {
            guard let conn = connections[serverId] else {
                NSLog("[%@ push-wake] no connection object for %@", ts, serverId)
                continue
            }
            NSLog("[%@ push-wake] server %@ isConnected=%d, reconnecting", ts, serverId, conn.isConnected ? 1 : 0)
            conn.disconnect()
            await conn.connect()
            NSLog("[%@ push-wake] server %@ after connect: isConnected=%d", ts, serverId, conn.isConnected ? 1 : 0)
        }

        for key in keys {
            guard let conn = connections[key.serverId], conn.isConnected,
                  let thread = threads[key] else { continue }
            do {
                let response = try await conn.readThread(threadId: key.threadId)
                let restored = restoredMessages(
                    from: response.thread.turns,
                    serverId: key.serverId,
                    defaultAgentNickname: response.thread.agentNickname ?? thread.agentNickname,
                    defaultAgentRole: response.thread.agentRole ?? thread.agentRole
                )
                thread.messages = restored
                if let model = response.model { thread.model = model }
                if let cwd = response.cwd { thread.cwd = cwd }
                let lastTurn = response.thread.turns.last
                let lastTurnStatus = lastTurn?.status
                let turnCount = response.thread.turns.count
                NSLog("[%@ push-wake] read %@ turns=%d lastStatus=%@ msgs=%d", ts, key.threadId, turnCount, lastTurnStatus ?? "nil", restored.count)
                let turnDone = lastTurnStatus == "completed" || lastTurnStatus == "failed" || lastTurnStatus == "interrupted"
                if turnDone {
                    thread.status = .ready
                    thread.activeTurnId = nil
                }

                if turnDone {
                    backgroundedTurnKeys.remove(key)
                    endLiveActivity(key: key, phase: .completed)
                    postLocalNotificationIfNeeded(model: thread.model, threadPreview: thread.preview)
                } else {
                    updateLiveActivityBGWake(key: key)
                }
            } catch {
                NSLog("[%@ push-wake] readThread failed for %@: %@", ts, key.threadId, error.localizedDescription)
            }
        }

        for serverId in serverIds {
            connections[serverId]?.disconnect()
        }

        if backgroundedTurnKeys.isEmpty {
            deregisterPushProxy()
        }
    }


    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskID)
        backgroundTaskID = .invalid
    }

    // MARK: - Live Activity

    private func startLiveActivity(key: ThreadKey, model: String, cwd: String, prompt: String) {
        guard liveActivities[key] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[%@ la] start SKIP key=%@ (exists=%d enabled=%d)", ts, key.threadId, liveActivities[key] != nil ? 1 : 0, ActivityAuthorizationInfo().areActivitiesEnabled ? 1 : 0)
            return
        }
        let now = Date()
        let attributes = CodexTurnAttributes(threadId: key.threadId, model: model, cwd: cwd, startDate: now, prompt: String(prompt.prefix(120)))
        let state = CodexTurnAttributes.ContentState(phase: .thinking, elapsedSeconds: 0, toolCallCount: 0, activeThreadCount: 0, fileChangeCount: 0, contextPercent: 0)
        liveActivityStartDates[key] = now
        liveActivityToolCallCounts[key] = 0
        liveActivityFileChangeCounts[key] = 0
        do {
            liveActivities[key] = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            NSLog("[%@ la] STARTED key=%@ activityId=%@", ts, key.threadId, liveActivities[key]?.id ?? "nil")
        } catch {
            NSLog("[%@ la] FAILED to start: %@", ts, error.localizedDescription)
        }
    }

    private func updateLiveActivity(key: ThreadKey, phase: CodexTurnAttributes.ContentState.Phase, toolName: String? = nil) {
        guard let activity = liveActivities[key] else {
            NSLog("[%@ la] updatePhase SKIP key=%@ (no activity)", ts, key.threadId)
            return
        }
        if phase == .toolCall {
            liveActivityToolCallCounts[key, default: 0] += 1
        }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastUpdate = now - (liveActivityLastUpdateTimes[key] ?? 0)
        guard sinceLastUpdate > 2.0 else { return }
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: phase, toolName: toolName, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count, outputSnippet: liveActivityOutputSnippets[key], fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        liveActivityLastUpdateTimes[key] = now
        NSLog("[%@ la] UPDATE phase=%@ tool=%@ elapsed=%d", ts, phase.rawValue, toolName ?? "-", elapsed)
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func updateLiveActivityOutput(key: ThreadKey, thread: ThreadState) {
        guard let activity = liveActivities[key] else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastUpdate = now - (liveActivityLastUpdateTimes[key] ?? 0)
        guard sinceLastUpdate > 2.0 else { return }
        guard let lastMsg = thread.messages.last, lastMsg.role == .assistant else { return }
        let snippet = snippetText(lastMsg.text)
        guard !snippet.isEmpty, snippet != liveActivityOutputSnippets[key] else { return }
        liveActivityOutputSnippets[key] = snippet
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: .thinking, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count, outputSnippet: snippet, fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        liveActivityLastUpdateTimes[key] = now
        NSLog("[%@ la] UPDATE output elapsed=%d snippet=%@", ts, elapsed, String(snippet.prefix(40)))
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func endLiveActivity(key: ThreadKey, phase: CodexTurnAttributes.ContentState.Phase) {
        guard let activity = liveActivities[key] else {
            NSLog("[%@ la] END SKIP key=%@ (no activity)", ts, key.threadId)
            return
        }
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))
        NSLog("[%@ la] END key=%@ phase=%@ elapsed=%d activityId=%@", ts, key.threadId, phase.rawValue, elapsed, activity.id)
        let ctxPercent = contextPercent(for: key)
        let state = CodexTurnAttributes.ContentState(phase: phase, elapsedSeconds: elapsed, toolCallCount: liveActivityToolCallCounts[key, default: 0], activeThreadCount: liveActivities.count - 1, fileChangeCount: liveActivityFileChangeCounts[key, default: 0], contextPercent: ctxPercent)
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 60))
        Task { await activity.end(content, dismissalPolicy: .after(.now + 4)) }
        liveActivities.removeValue(forKey: key)
        liveActivityStartDates.removeValue(forKey: key)
        liveActivityToolCallCounts.removeValue(forKey: key)
        liveActivityOutputSnippets.removeValue(forKey: key)
        liveActivityLastUpdateTimes.removeValue(forKey: key)
        liveActivityFileChangeCounts.removeValue(forKey: key)
    }

    private func updateLiveActivityBGWake(key: ThreadKey) {
        guard let activity = liveActivities[key] else { return }
        let thread = threads[key]
        let elapsed = Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date()))

        let toolCount = liveActivityToolCallCounts[key, default: 0]

        if let lastAssistant = thread?.messages.last(where: { $0.role == .assistant && !$0.text.isEmpty }) {
            liveActivityOutputSnippets[key] = snippetText(lastAssistant.text)
        }

        let phase: CodexTurnAttributes.ContentState.Phase = thread?.hasTurnActive == true ? .thinking : .completed
        let ctxPercent = contextPercent(for: key)

        let state = CodexTurnAttributes.ContentState(
            phase: phase,
            elapsedSeconds: elapsed,
            toolCallCount: toolCount,
            activeThreadCount: liveActivities.count,
            outputSnippet: liveActivityOutputSnippets[key],
            pushCount: bgWakeCount,
            fileChangeCount: liveActivityFileChangeCounts[key, default: 0],
            contextPercent: ctxPercent
        )
        NSLog("[%@ la] BG WAKE UPDATE #%d elapsed=%d tools=%d snippet=%@", ts, bgWakeCount, elapsed, toolCount, liveActivityOutputSnippets[key] ?? "nil")
        liveActivityLastUpdateTimes[key] = CFAbsoluteTimeGetCurrent()
        Task { await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60))) }
    }

    private func snippetText(_ text: String) -> String {
        String(text.prefix(120))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private func contextPercent(for key: ThreadKey) -> Int {
        guard let t = threads[key],
              let window = t.modelContextWindow, window > 0,
              let used = t.contextTokensUsed else { return 0 }
        return min(100, Int(Double(used) / Double(window) * 100))
    }

    private func endAllLiveActivities(phase: CodexTurnAttributes.ContentState.Phase) {
        for key in liveActivities.keys {
            endLiveActivity(key: key, phase: phase)
        }
    }

    // MARK: - Local Notifications

    private func requestNotificationPermissionIfNeeded() {
        guard !notificationPermissionRequested else { return }
        notificationPermissionRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func postLocalNotificationIfNeeded(model: String, threadPreview: String? = nil) {
        guard UIApplication.shared.applicationState != .active else { return }
        let content = UNMutableNotificationContent()
        content.title = "Turn completed"
        var bodyParts: [String] = []
        if let preview = threadPreview, !preview.isEmpty { bodyParts.append(preview) }
        if !model.isEmpty { bodyParts.append(model) }
        content.body = bodyParts.joined(separator: " - ")
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Persistence

    func saveServerList() {
        let saved = connections.values.map { SavedServer.from($0.server) }
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: savedServersKey)
        }
    }

    func loadSavedServers() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    // MARK: - Message Restoration

    func restoredMessages(
        from turns: [ResumedTurn],
        serverId: String? = nil,
        defaultAgentNickname: String? = nil,
        defaultAgentRole: String? = nil
    ) -> [ChatMessage] {
        var restored: [ChatMessage] = []
        restored.reserveCapacity(turns.count * 3)
        for (turnIndex, turn) in turns.enumerated() {
            for item in turn.items {
                if let msg = chatMessage(
                    from: item,
                    sourceTurnId: turn.id,
                    sourceTurnIndex: turnIndex,
                    serverId: serverId,
                    defaultAgentNickname: defaultAgentNickname,
                    defaultAgentRole: defaultAgentRole
                ) {
                    restored.append(msg)
                }
            }
        }
        return restored
    }

    private func chatMessage(
        from item: ResumedThreadItem,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        serverId: String?,
        defaultAgentNickname: String? = nil,
        defaultAgentRole: String? = nil
    ) -> ChatMessage? {
        switch item {
        case .userMessage(let content):
            let (text, images) = renderUserInput(content)
            if text.isEmpty && images.isEmpty { return nil }
            return ChatMessage(
                role: .user,
                text: text,
                images: images,
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex,
                isFromUserTurnBoundary: true
            )
        case .agentMessage(let text, _, let itemAgentId, let itemAgentNickname, let itemAgentRole):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            let normalizedNickname = sanitizedLineageId(itemAgentNickname) ?? sanitizedLineageId(defaultAgentNickname)
            let normalizedRole = sanitizedLineageId(itemAgentRole) ?? sanitizedLineageId(defaultAgentRole)
            upsertAgentDirectory(
                serverId: serverId,
                threadId: nil,
                agentId: itemAgentId,
                nickname: normalizedNickname,
                role: normalizedRole
            )
            return ChatMessage(
                role: .assistant,
                text: trimmed,
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex,
                agentNickname: normalizedNickname,
                agentRole: normalizedRole
            )
        case .plan(let text):
            return withTurnMetadata(
                systemMessage(title: "Plan", body: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .reasoning(let summary, let content):
            let summaryText = summary
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            let detailText = content
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
            var sections: [String] = []
            if !summaryText.isEmpty { sections.append(summaryText) }
            if !detailText.isEmpty { sections.append(detailText) }
            return withTurnMetadata(
                systemMessage(title: "Reasoning", body: sections.joined(separator: "\n\n")),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .commandExecution(let command, let cwd, let status, let output, let exitCode, let durationMs):
            var lines: [String] = ["Status: \(status)"]
            if !cwd.isEmpty { lines.append("Directory: \(cwd)") }
            if let exitCode { lines.append("Exit code: \(exitCode)") }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            var body = lines.joined(separator: "\n")
            if !command.isEmpty { body += "\n\nCommand:\n```bash\n\(command)\n```" }
            if let output {
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { body += "\n\nOutput:\n```text\n\(trimmed)\n```" }
            }
            return withTurnMetadata(
                systemMessage(title: "Command Execution", body: body),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .fileChange(let changes, let status):
            if changes.isEmpty {
                return withTurnMetadata(
                    systemMessage(title: "File Change", body: "Status: \(status)"),
                    sourceTurnId: sourceTurnId,
                    sourceTurnIndex: sourceTurnIndex
                )
            }
            var parts: [String] = []
            for change in changes {
                var body = "Path: \(change.path)\nKind: \(change.kind)"
                let diff = change.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                if !diff.isEmpty { body += "\n\n```diff\n\(diff)\n```" }
                parts.append(body)
            }
            return withTurnMetadata(
                systemMessage(title: "File Change", body: "Status: \(status)\n\n" + parts.joined(separator: "\n\n---\n\n")),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .mcpToolCall(let server, let tool, let status, let result, let error, let durationMs):
            var lines: [String] = ["Status: \(status)"]
            if !server.isEmpty || !tool.isEmpty {
                lines.append("Tool: \(server.isEmpty ? tool : "\(server)/\(tool)")")
            }
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            if let errorMessage = error?.message, !errorMessage.isEmpty {
                lines.append("Error: \(errorMessage)")
            }
            var body = lines.joined(separator: "\n")
            if let result {
                let resultObject: [String: Any] = [
                    "content": result.content.map { $0.value },
                    "structuredContent": result.structuredContent?.value ?? NSNull()
                ]
                if let pretty = prettyJSON(resultObject) {
                    body += "\n\nResult:\n```json\n\(pretty)\n```"
                }
            }
            return withTurnMetadata(
                systemMessage(title: "MCP Tool Call", body: body),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .collabAgentToolCall(let tool, let status, let receiverThreadIds, let receiverAgents, let prompt):
            var lines: [String] = ["Status: \(status)", "Tool: \(tool)"]
            if !receiverThreadIds.isEmpty || !receiverAgents.isEmpty {
                var labels: [String] = []
                var seenIds: Set<String> = []
                var consumedReceiverAgentIndexes: Set<Int> = []
                let normalizedTargets = receiverThreadIds.compactMap { sanitizedLineageId($0) }
                let listsAlignByIndex = normalizedTargets.count == receiverAgents.count

                for agent in receiverAgents {
                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: agent.threadId,
                        agentId: agent.agentId,
                        nickname: agent.agentNickname,
                        role: agent.agentRole
                    )
                }

                for (targetIndex, targetId) in normalizedTargets.enumerated() {
                    if seenIds.contains(targetId) { continue }
                    seenIds.insert(targetId)

                    var matchedReason = "source=receiver-targets"
                    var overrideIndex: Int?
                    if let index = receiverAgents.firstIndex(where: { sanitizedLineageId($0.threadId) == targetId }) {
                        overrideIndex = index
                        matchedReason = "source=receiverAgents.threadId"
                    } else if let index = receiverAgents.firstIndex(where: { sanitizedLineageId($0.agentId) == targetId }) {
                        overrideIndex = index
                        matchedReason = "source=receiverAgents.agentId"
                    } else if listsAlignByIndex, receiverAgents.indices.contains(targetIndex) {
                        overrideIndex = targetIndex
                        matchedReason = "source=aligned-index-\(targetIndex)"
                    }

                    if let overrideIndex {
                        consumedReceiverAgentIndexes.insert(overrideIndex)
                    }
                    let override = overrideIndex.flatMap { receiverAgents[$0] }
                    let overrideThreadId = sanitizedLineageId(override?.threadId)
                    let overrideAgentId = sanitizedLineageId(override?.agentId)
                    let directoryThreadMatch = mergedAgentDirectoryEntry(serverId: serverId, threadId: targetId, agentId: nil) != nil
                    let directoryAgentMatch = mergedAgentDirectoryEntry(serverId: serverId, threadId: nil, agentId: targetId) != nil
                    let prefersAgentTarget: Bool
                    if overrideAgentId == targetId {
                        prefersAgentTarget = true
                    } else if overrideThreadId == targetId {
                        prefersAgentTarget = false
                    } else if directoryAgentMatch && !directoryThreadMatch {
                        prefersAgentTarget = true
                    } else if directoryThreadMatch && !directoryAgentMatch {
                        prefersAgentTarget = false
                    } else {
                        prefersAgentTarget = overrideThreadId == nil && overrideAgentId != nil
                    }

                    let directoryEntry = mergedAgentDirectoryEntry(serverId: serverId, threadId: targetId, agentId: targetId)
                    let lookupThreadId = overrideThreadId
                        ?? directoryEntry?.threadId
                        ?? (prefersAgentTarget ? nil : targetId)
                    let fallback = serverId.flatMap { server in
                        lookupThreadId.map { resolveAgentIdentity(serverId: server, threadId: $0) }
                    }

                    let resolvedThreadId = overrideThreadId
                        ?? directoryEntry?.threadId
                        ?? fallback?.threadId
                        ?? (prefersAgentTarget ? nil : targetId)
                    let resolvedAgentId = overrideAgentId
                        ?? directoryEntry?.agentId
                        ?? fallback?.agentId
                        ?? (prefersAgentTarget ? targetId : nil)
                    let resolvedNickname = sanitizedLineageId(override?.agentNickname)
                        ?? directoryEntry?.nickname
                        ?? fallback?.nickname
                    let resolvedRole = sanitizedLineageId(override?.agentRole)
                        ?? directoryEntry?.role
                        ?? fallback?.role

                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: resolvedThreadId,
                        agentId: resolvedAgentId,
                        nickname: resolvedNickname,
                        role: resolvedRole
                    )

                    let label = formatAgentLabel(
                        nickname: resolvedNickname,
                        role: resolvedRole,
                        fallbackThreadId: resolvedThreadId ?? resolvedAgentId ?? targetId
                    ) ?? targetId
                    labels.append(label)

                    if resolvedNickname != nil || resolvedRole != nil {
                        logTargetResolution(
                            targetId: targetId,
                            resolvedLabel: label,
                            reason: "resolved-via=\(matchedReason)"
                        )
                    } else {
                        logTargetResolution(
                            targetId: targetId,
                            resolvedLabel: label,
                            reason: "unresolved reason=no-metadata \(matchedReason)"
                        )
                    }
                    if let resolvedThreadId {
                        seenIds.insert(resolvedThreadId)
                    }
                    if let resolvedAgentId {
                        seenIds.insert(resolvedAgentId)
                    }
                }

                for (agentIndex, agent) in receiverAgents.enumerated() {
                    if consumedReceiverAgentIndexes.contains(agentIndex) { continue }
                    let normalizedThreadId = sanitizedLineageId(agent.threadId)
                    let normalizedAgentId = sanitizedLineageId(agent.agentId)
                    let targetId = normalizedThreadId ?? normalizedAgentId
                    guard let targetId else { continue }
                    if seenIds.contains(targetId) { continue }
                    seenIds.insert(targetId)

                    let directoryEntry = mergedAgentDirectoryEntry(
                        serverId: serverId,
                        threadId: normalizedThreadId,
                        agentId: normalizedAgentId
                    )
                    let lookupThreadId = normalizedThreadId ?? directoryEntry?.threadId
                    let fallback = serverId.flatMap { server in
                        lookupThreadId.map { resolveAgentIdentity(serverId: server, threadId: $0) }
                    }
                    let resolvedThreadId = normalizedThreadId ?? directoryEntry?.threadId ?? fallback?.threadId
                    let resolvedAgentId = normalizedAgentId
                        ?? directoryEntry?.agentId
                        ?? fallback?.agentId
                        ?? (resolvedThreadId == nil ? targetId : nil)
                    let resolvedNickname = sanitizedLineageId(agent.agentNickname)
                        ?? directoryEntry?.nickname
                        ?? fallback?.nickname
                    let resolvedRole = sanitizedLineageId(agent.agentRole)
                        ?? directoryEntry?.role
                        ?? fallback?.role

                    upsertAgentDirectory(
                        serverId: serverId,
                        threadId: resolvedThreadId,
                        agentId: resolvedAgentId,
                        nickname: resolvedNickname,
                        role: resolvedRole
                    )
                    let label = formatAgentLabel(
                        nickname: resolvedNickname,
                        role: resolvedRole,
                        fallbackThreadId: resolvedThreadId ?? resolvedAgentId ?? targetId
                    ) ?? targetId
                    labels.append(label)

                    if resolvedNickname != nil || resolvedRole != nil {
                        logTargetResolution(
                            targetId: targetId,
                            resolvedLabel: label,
                            reason: "resolved-via=receiver-agent-ref"
                        )
                    } else {
                        logTargetResolution(
                            targetId: targetId,
                            resolvedLabel: label,
                            reason: "unresolved reason=receiver-agent-ref-missing-metadata"
                        )
                    }
                    if let resolvedThreadId {
                        seenIds.insert(resolvedThreadId)
                    }
                    if let resolvedAgentId {
                        seenIds.insert(resolvedAgentId)
                    }
                }

                if !labels.isEmpty {
                    lines.append("Targets: \(labels.joined(separator: ", "))")
                }
            }
            if let prompt {
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append("")
                    lines.append("Prompt:")
                    lines.append(trimmed)
                }
            }
            return withTurnMetadata(
                systemMessage(title: "Collaboration", body: lines.joined(separator: "\n")),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .webSearch(let query, let action):
            var lines: [String] = ["Status: completed"]
            if !query.isEmpty { lines.append("Query: \(query)") }
            if let action, let pretty = prettyJSON(action.value) {
                lines.append("")
                lines.append("Action:")
                lines.append("```json\n\(pretty)\n```")
            }
            return withTurnMetadata(
                systemMessage(title: "Web Search", body: lines.joined(separator: "\n")),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .imageView(let path):
            return withTurnMetadata(
                systemMessage(title: "Image View", body: "Path: \(path)"),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .enteredReviewMode(let review):
            return withTurnMetadata(
                systemMessage(title: "Review Mode", body: "Entered review: \(review)"),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .exitedReviewMode(let review):
            return withTurnMetadata(
                systemMessage(title: "Review Mode", body: "Exited review: \(review)"),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .dynamicToolCall(let tool, let arguments, let status, _, let durationMs):
            if tool == GenerativeUITools.readMeToolName {
                return nil
            }
            if tool == GenerativeUITools.showWidgetToolName {
                guard let args = arguments?.value as? [String: Any],
                      let code = args["widget_code"] as? String, !code.isEmpty else { return nil }
                let widget = WidgetState.fromArguments(args, callId: UUID().uuidString, isFinalized: true)
                var msg = ChatMessage(
                    role: .system,
                    text: "### Widget\nstatus: completed\n\nWidget: \(widget.title)",
                    widgetState: widget
                )
                msg.sourceTurnId = sourceTurnId
                msg.sourceTurnIndex = sourceTurnIndex
                return msg
            }
            var lines: [String] = ["Status: \(status)", "Tool: \(tool)"]
            if let durationMs { lines.append("Duration: \(durationMs) ms") }
            return withTurnMetadata(
                systemMessage(title: "Dynamic Tool Call", body: lines.joined(separator: "\n")),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .contextCompaction:
            return withTurnMetadata(
                systemMessage(title: "Context", body: "Context compaction occurred."),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .unknown(let type):
            return withTurnMetadata(
                systemMessage(title: "Event", body: "Unhandled item type: \(type)"),
                sourceTurnId: sourceTurnId,
                sourceTurnIndex: sourceTurnIndex
            )
        case .ignored:
            return nil
        }
    }

    private func withTurnMetadata(
        _ message: ChatMessage?,
        sourceTurnId: String?,
        sourceTurnIndex: Int?
    ) -> ChatMessage? {
        guard let message else { return nil }
        return ChatMessage(
            role: message.role,
            text: message.text,
            images: message.images,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            isFromUserTurnBoundary: message.isFromUserTurnBoundary,
            agentNickname: message.agentNickname,
            agentRole: message.agentRole
        )
    }

    private func systemMessage(title: String, body: String) -> ChatMessage? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return ChatMessage(role: .system, text: "### \(title)\n\(trimmed)")
    }

    private func renderUserInput(_ content: [ResumedUserInput]) -> (String, [ChatImage]) {
        var textParts: [String] = []
        var images: [ChatImage] = []
        for input in content {
            switch input.type {
            case "text":
                let trimmed = input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !trimmed.isEmpty { textParts.append(trimmed) }
            case "image":
                if let url = input.url, let imageData = decodeBase64DataURI(url) {
                    images.append(ChatImage(data: imageData))
                }
            case "localImage":
                if let path = input.path, let data = FileManager.default.contents(atPath: path) {
                    images.append(ChatImage(data: data))
                }
            case "skill":
                let name = (input.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let path = (input.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !path.isEmpty { textParts.append("[Skill] \(name) (\(path))") }
                else if !name.isEmpty { textParts.append("[Skill] \(name)") }
                else if !path.isEmpty { textParts.append("[Skill] \(path)") }
            case "mention":
                let name = (input.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let path = (input.path ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty && !path.isEmpty { textParts.append("[Mention] \(name) (\(path))") }
                else if !name.isEmpty { textParts.append("[Mention] \(name)") }
                else if !path.isEmpty { textParts.append("[Mention] \(path)") }
            default:
                break
            }
        }
        return (textParts.joined(separator: "\n"), images)
    }

    private func decodeBase64DataURI(_ uri: String) -> Data? {
        guard uri.hasPrefix("data:") else { return nil }
        guard let commaIndex = uri.firstIndex(of: ",") else { return nil }
        let base64 = String(uri[uri.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func prettyJSON(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              var text = String(data: data, encoding: .utf8) else {
            return nil
        }
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}
