import Foundation
import Combine

@MainActor
final class ServerManager: ObservableObject {
    @Published var connections: [String: ServerConnection] = [:]
    @Published var threads: [ThreadKey: ThreadState] = [:]
    @Published var activeThreadKey: ThreadKey?
    @Published var pendingApprovals: [PendingApproval] = []

    private let savedServersKey = "codex_saved_servers"
    private var threadSubscriptions: [ThreadKey: AnyCancellable] = [:]
    private var liveItemMessageIndices: [ThreadKey: [String: Int]] = [:]
    private var liveTurnDiffMessageIndices: [ThreadKey: [String: Int]] = [:]
    private var serversUsingItemNotifications: Set<String> = []

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
        let createdAt: Date
    }

    /// Call after inserting a new ThreadState into `threads` to forward its changes.
    private func observeThread(_ thread: ThreadState) {
        threadSubscriptions[thread.key] = thread.objectWillChange
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

    // MARK: - Server Lifecycle

    func addServer(_ server: DiscoveredServer, target: ConnectionTarget) async {
        if let existing = connections[server.id] {
            configureConnectionCallbacks(existing, serverId: server.id)
            if !existing.isConnected {
                await existing.connect()
                if existing.isConnected {
                    await refreshSessions(for: server.id)
                }
            }
            return
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
            self?.removePendingApprovals(forServerId: serverId)
            self?.objectWillChange.send()
        }
    }

    func removeServer(id: String) {
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        removePendingApprovals(forServerId: id)
        for key in threads.keys where key.serverId == id {
            threadSubscriptions.removeValue(forKey: key)
            liveItemMessageIndices.removeValue(forKey: key)
            liveTurnDiffMessageIndices.removeValue(forKey: key)
        }
        serversUsingItemNotifications.remove(id)
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
        sandboxMode: String? = nil
    ) async -> ThreadKey? {
        guard let conn = connections[serverId] else { return nil }
        do {
            let resp = try await conn.startThread(
                cwd: cwd,
                model: model,
                approvalPolicy: approvalPolicy,
                sandboxMode: sandboxMode
            )
            let threadId = resp.thread.id
            let key = ThreadKey(serverId: serverId, threadId: threadId)
            let state = ThreadState(
                serverId: serverId,
                threadId: threadId,
                serverName: conn.server.name,
                serverSource: conn.server.source
            )
            state.cwd = cwd
            state.updatedAt = Date()
            threads[key] = state
            liveItemMessageIndices[key] = nil
            liveTurnDiffMessageIndices[key] = nil
            observeThread(state)
            activeThreadKey = key
            return key
        } catch {
            return nil
        }
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
            state.messages = restoredMessages(from: resp.thread.turns)
            liveItemMessageIndices[key] = nil
            liveTurnDiffMessageIndices[key] = nil
            state.cwd = cwd
            state.status = .ready
            state.updatedAt = Date()
            activeThreadKey = key
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
        }
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
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"]),
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "cmdId", "cmd_id"]),
                command: command?.isEmpty == true ? nil : command,
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                createdAt: Date()
            )
        case "item/fileChange/requestApproval":
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: extractString(params, keys: ["threadId", "thread_id", "conversationId", "conversation_id"]),
                turnId: extractString(params, keys: ["turnId", "turn_id"]),
                itemId: extractString(params, keys: ["itemId", "item_id", "callId", "call_id", "patchId", "patch_id"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot", "grant_root"]),
                createdAt: Date()
            )
        case "execCommandApproval":
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .commandExecution,
                threadId: extractString(params, keys: ["conversationId", "threadId"]),
                turnId: nil,
                itemId: extractString(params, keys: ["approvalId", "callId", "cmdId"]),
                command: commandString(from: params),
                cwd: extractString(params, keys: ["cwd"]),
                reason: extractString(params, keys: ["reason"]),
                grantRoot: nil,
                createdAt: Date()
            )
        case "applyPatchApproval":
            pending = PendingApproval(
                id: requestId,
                requestId: requestId,
                serverId: serverId,
                method: method,
                kind: .fileChange,
                threadId: extractString(params, keys: ["conversationId", "threadId"]),
                turnId: nil,
                itemId: extractString(params, keys: ["callId", "patchId"]),
                command: nil,
                cwd: nil,
                reason: extractString(params, keys: ["reason"]),
                grantRoot: extractString(params, keys: ["grantRoot"]),
                createdAt: Date()
            )
        default:
            return false
        }

        pendingApprovals.append(pending)
        return true
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
        cwd: String,
        model: String? = nil,
        effort: String? = nil,
        approvalPolicy: String = "never",
        sandboxMode: String? = nil
    ) async {
        var key = activeThreadKey
        if key == nil {
            if let serverId = connections.values.first(where: { $0.isConnected })?.id {
                key = await startThread(
                    serverId: serverId,
                    cwd: cwd,
                    model: model,
                    approvalPolicy: approvalPolicy,
                    sandboxMode: sandboxMode
                )
            }
        }
        guard let key, let thread = threads[key], let conn = connections[key.serverId] else { return }
        thread.messages.append(ChatMessage(role: .user, text: text))
        thread.status = .thinking
        thread.updatedAt = Date()
        do {
            try await conn.sendTurn(threadId: key.threadId, text: text, model: model, effort: effort)
        } catch {
            thread.status = .error(error.localizedDescription)
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

    func interrupt() async {
        guard let key = activeThreadKey, let conn = connections[key.serverId] else { return }
        await conn.interrupt(threadId: key.threadId)
        threads[key]?.status = .ready
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
                    state.updatedAt = Date(timeIntervalSince1970: TimeInterval(summary.updatedAt))
                    threads[key] = state
                    observeThread(state)
                }
            }
        } catch {}
    }

    // MARK: - Notification Routing

    func handleNotification(serverId: String, method: String, data: Data) {
        switch method {
        case "account/login/completed", "account/updated":
            connections[serverId]?.handleAccountNotification(method: method, data: data)

        case "turn/started":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .thinking
            }

        case "item/agentMessage/delta":
            struct DeltaParams: Decodable { let delta: String; let threadId: String? }
            struct DeltaNotif: Decodable { let params: DeltaParams }
            guard let notif = try? JSONDecoder().decode(DeltaNotif.self, from: data),
                  !notif.params.delta.isEmpty else { return }
            let key = resolveThreadKey(serverId: serverId, threadId: notif.params.threadId)
            guard let thread = threads[key] else { return }
            if let last = thread.messages.last, last.role == .assistant {
                thread.messages[thread.messages.count - 1].text += notif.params.delta
            } else {
                thread.messages.append(ChatMessage(role: .assistant, text: notif.params.delta))
            }
            thread.updatedAt = Date()

        case "turn/completed", "codex/event/task_complete":
            if let threadId = extractThreadId(from: data) {
                let key = ThreadKey(serverId: serverId, threadId: threadId)
                threads[key]?.status = .ready
                threads[key]?.updatedAt = Date()
                liveItemMessageIndices[key] = nil
                liveTurnDiffMessageIndices[key] = nil
                if activeThreadKey == key {
                    Task { @MainActor in
                        await syncThreadFromServer(key)
                    }
                }
            } else {
                // Fallback: mark any thinking thread on this server as ready
                for (_, thread) in threads where thread.serverId == serverId && thread.hasTurnActive {
                    thread.status = .ready
                    thread.updatedAt = Date()
                    liveItemMessageIndices[thread.key] = nil
                    liveTurnDiffMessageIndices[thread.key] = nil
                }
                if let key = activeThreadKey {
                    Task { @MainActor in
                        await syncThreadFromServer(key)
                    }
                }
            }

        case "turn/diff/updated":
            handleTurnDiffNotification(serverId: serverId, data: data)

        default:
            if method.hasPrefix("item/") {
                handleItemNotification(serverId: serverId, method: method, data: data)
            } else if method == "codex/event/turn_diff" {
                handleLegacyCodexEventNotification(serverId: serverId, method: method, data: data)
            } else if (method == "codex/event" || method.hasPrefix("codex/event/")),
                      !serversUsingItemNotifications.contains(serverId) {
                handleLegacyCodexEventNotification(serverId: serverId, method: method, data: data)
            }
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
            // agentMessage is streamed via delta; userMessage is added locally in send()
            if let itemType = itemDict["type"] as? String,
               itemType == "agentMessage" || itemType == "userMessage" {
                return
            }
            guard let itemData = try? JSONSerialization.data(withJSONObject: itemDict),
                  let item = try? JSONDecoder().decode(ResumedThreadItem.self, from: itemData),
                  let msg = chatMessage(from: item) else { return }
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

    func syncActiveThreadFromServer() async {
        guard let key = activeThreadKey else { return }
        await syncThreadFromServer(key)
    }

    private func syncThreadFromServer(_ key: ThreadKey) async {
        guard let conn = connections[key.serverId], conn.isConnected,
              let thread = threads[key] else { return }
        if thread.hasTurnActive { return }

        let cwd = thread.cwd.isEmpty ? "/tmp" : thread.cwd
        guard let response = try? await conn.resumeThread(threadId: key.threadId, cwd: cwd) else { return }
        let restored = restoredMessages(from: response.thread.turns)
        guard !messagesEquivalent(thread.messages, restored) else { return }
        if shouldPreferLocalMessages(current: thread.messages, restored: restored) { return }

        thread.messages = restored
        thread.updatedAt = Date()
        liveItemMessageIndices[key] = nil
        liveTurnDiffMessageIndices[key] = nil
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

    func restoredMessages(from turns: [ResumedTurn]) -> [ChatMessage] {
        var restored: [ChatMessage] = []
        restored.reserveCapacity(turns.count * 3)
        for turn in turns {
            for item in turn.items {
                if let msg = chatMessage(from: item) {
                    restored.append(msg)
                }
            }
        }
        return restored
    }

    private func chatMessage(from item: ResumedThreadItem) -> ChatMessage? {
        switch item {
        case .userMessage(let content):
            let (text, images) = renderUserInput(content)
            if text.isEmpty && images.isEmpty { return nil }
            return ChatMessage(role: .user, text: text, images: images)
        case .agentMessage(let text, _):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return nil }
            return ChatMessage(role: .assistant, text: trimmed)
        case .plan(let text):
            return systemMessage(title: "Plan", body: text.trimmingCharacters(in: .whitespacesAndNewlines))
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
            return systemMessage(title: "Reasoning", body: sections.joined(separator: "\n\n"))
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
            return systemMessage(title: "Command Execution", body: body)
        case .fileChange(let changes, let status):
            if changes.isEmpty {
                return systemMessage(title: "File Change", body: "Status: \(status)")
            }
            var parts: [String] = []
            for change in changes {
                var body = "Path: \(change.path)\nKind: \(change.kind)"
                let diff = change.diff.trimmingCharacters(in: .whitespacesAndNewlines)
                if !diff.isEmpty { body += "\n\n```diff\n\(diff)\n```" }
                parts.append(body)
            }
            return systemMessage(title: "File Change", body: "Status: \(status)\n\n" + parts.joined(separator: "\n\n---\n\n"))
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
            return systemMessage(title: "MCP Tool Call", body: body)
        case .collabAgentToolCall(let tool, let status, let receiverThreadIds, let prompt):
            var lines: [String] = ["Status: \(status)", "Tool: \(tool)"]
            if !receiverThreadIds.isEmpty {
                lines.append("Targets: \(receiverThreadIds.joined(separator: ", "))")
            }
            if let prompt {
                let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    lines.append("")
                    lines.append("Prompt:")
                    lines.append(trimmed)
                }
            }
            return systemMessage(title: "Collaboration", body: lines.joined(separator: "\n"))
        case .webSearch(let query, let action):
            var lines: [String] = []
            if !query.isEmpty { lines.append("Query: \(query)") }
            if let action, let pretty = prettyJSON(action.value) {
                lines.append("")
                lines.append("Action:")
                lines.append("```json\n\(pretty)\n```")
            }
            return systemMessage(title: "Web Search", body: lines.joined(separator: "\n"))
        case .imageView(let path):
            return systemMessage(title: "Image View", body: "Path: \(path)")
        case .enteredReviewMode(let review):
            return systemMessage(title: "Review Mode", body: "Entered review: \(review)")
        case .exitedReviewMode(let review):
            return systemMessage(title: "Review Mode", body: "Exited review: \(review)")
        case .contextCompaction:
            return systemMessage(title: "Context", body: "Context compaction occurred.")
        case .unknown(let type):
            return systemMessage(title: "Event", body: "Unhandled item type: \(type)")
        case .ignored:
            return nil
        }
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
