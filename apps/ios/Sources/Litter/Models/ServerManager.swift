import Foundation
import Combine

@MainActor
final class ServerManager: ObservableObject {
    @Published var connections: [String: ServerConnection] = [:]
    @Published var threads: [ThreadKey: ThreadState] = [:]
    @Published var activeThreadKey: ThreadKey?

    private let savedServersKey = "codex_saved_servers"
    private var threadSubscriptions: [ThreadKey: AnyCancellable] = [:]

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

    var hasAnyConnection: Bool {
        connections.values.contains { $0.isConnected }
    }

    // MARK: - Server Lifecycle

    func addServer(_ server: DiscoveredServer, target: ConnectionTarget) async {
        if let existing = connections[server.id] {
            if !existing.isConnected {
                await existing.connect()
                if existing.isConnected {
                    await refreshSessions(for: server.id)
                }
            }
            return
        }

        let conn = ServerConnection(server: server, target: target)
        conn.onNotification = { [weak self] method, data in
            self?.handleNotification(serverId: server.id, method: method, data: data)
        }
        conn.onDisconnect = { [weak self] in
            self?.objectWillChange.send()
        }
        connections[server.id] = conn
        saveServerList()
        await conn.connect()
        if conn.isConnected {
            await refreshSessions(for: server.id)
        }
    }

    func removeServer(id: String) {
        connections[id]?.disconnect()
        connections.removeValue(forKey: id)
        for key in threads.keys where key.serverId == id {
            threadSubscriptions.removeValue(forKey: key)
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

    func startThread(serverId: String, cwd: String, model: String? = nil) async -> ThreadKey? {
        guard let conn = connections[serverId] else { return nil }
        do {
            let resp = try await conn.startThread(cwd: cwd, model: model)
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
            observeThread(state)
            activeThreadKey = key
            return key
        } catch {
            return nil
        }
    }

    func resumeThread(serverId: String, threadId: String, cwd: String) async -> Bool {
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
            let resp = try await conn.resumeThread(threadId: threadId, cwd: cwd)
            state.messages = restoredMessages(from: resp.thread.turns)
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

    func viewThread(_ key: ThreadKey) async {
        if threads[key]?.messages.isEmpty == true {
            let cwd = threads[key]?.cwd ?? "/tmp"
            _ = await resumeThread(serverId: key.serverId, threadId: key.threadId, cwd: cwd)
        } else {
            activeThreadKey = key
        }
    }

    // MARK: - Send / Interrupt

    func send(_ text: String, cwd: String, model: String? = nil, effort: String? = nil) async {
        var key = activeThreadKey
        if key == nil {
            if let serverId = connections.values.first(where: { $0.isConnected })?.id {
                key = await startThread(serverId: serverId, cwd: cwd, model: model)
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
            } else {
                // Fallback: mark any thinking thread on this server as ready
                for (_, thread) in threads where thread.serverId == serverId && thread.hasTurnActive {
                    thread.status = .ready
                    thread.updatedAt = Date()
                }
            }

        default:
            if method.hasPrefix("item/") {
                handleItemNotification(serverId: serverId, method: method, data: data)
            }
        }
    }

    private func handleItemNotification(serverId: String, method: String, data: Data) {
        // Format: item/started or item/completed → params.item has the ThreadItem with "type"
        //         item/agentMessage/delta etc. → streaming deltas, skip (agentMessage/delta handled above)
        struct ItemNotification: Decodable { let params: AnyCodable? }
        guard let raw = try? JSONDecoder().decode(ItemNotification.self, from: data),
              let paramsDict = raw.params?.value as? [String: Any] else { return }

        let threadId = paramsDict["threadId"] as? String

        // Only show completed items — started has incomplete data and would duplicate
        guard method == "item/completed" else { return }
        guard let itemDict = paramsDict["item"] as? [String: Any] else { return }

        // agentMessage is streamed via delta; userMessage is added locally in send()
        if let itemType = itemDict["type"] as? String,
           itemType == "agentMessage" || itemType == "userMessage" { return }

        guard let itemData = try? JSONSerialization.data(withJSONObject: itemDict),
              let item = try? JSONDecoder().decode(ResumedThreadItem.self, from: itemData),
              let msg = chatMessage(from: item) else { return }
        let key = resolveThreadKey(serverId: serverId, threadId: threadId)
        guard let thread = threads[key] else { return }
        thread.messages.append(msg)
        thread.updatedAt = Date()
    }

    private func extractThreadId(from data: Data) -> String? {
        struct Wrapper: Decodable {
            struct Params: Decodable { let threadId: String? }
            let params: Params?
        }
        return (try? JSONDecoder().decode(Wrapper.self, from: data))?.params?.threadId
    }

    private func resolveThreadKey(serverId: String, threadId: String?) -> ThreadKey {
        if let threadId {
            return ThreadKey(serverId: serverId, threadId: threadId)
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
