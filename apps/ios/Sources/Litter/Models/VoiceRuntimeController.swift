import ActivityKit
import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class VoiceRuntimeController: VoiceActions {
    static let shared = VoiceRuntimeController()
    static let localServerID = "local"
    static let persistedLocalVoiceThreadIDKey = "litter.voice.local.thread_id"

    private(set) var activeVoiceSession: VoiceSessionState?
    var handoffModel: String?
    var handoffEffort: String?
    var handoffFastMode = false

    @ObservationIgnored private weak var appModel: AppModel?
    @ObservationIgnored private let voiceSessionCoordinator = VoiceSessionCoordinator()
    @ObservationIgnored private lazy var handoffManager = RustHandoffManager(localServerId: Self.localServerID)
    @ObservationIgnored private var updateSubscription: AppStoreSubscription?
    @ObservationIgnored private var eventTask: Task<Void, Never>?
    @ObservationIgnored private var handoffActionPollTask: Task<Void, Never>?
    @ObservationIgnored private var voiceCallActivity: Activity<CodexVoiceCallAttributes>?
    @ObservationIgnored private var voiceInputDecayToken: UUID?
    @ObservationIgnored private var voiceOutputDecayToken: UUID?
    @ObservationIgnored private var voiceStopRequestedThreadKey: ThreadKey?
    @ObservationIgnored private var lastHandledVoiceEndRequestToken: String?

    init() {
        voiceSessionCoordinator.onEvent = { [weak self] event in
            self?.handleVoiceSessionCoordinatorEvent(event)
        }
        installVoiceSessionControlObserver()
    }

    deinit {
        eventTask?.cancel()
        handoffActionPollTask?.cancel()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let name = CFNotificationName(VoiceSessionControl.endRequestDarwinNotification as CFString)
        CFNotificationCenterRemoveObserver(center, observer, name, nil)
    }

    func bind(appModel: AppModel) {
        self.appModel = appModel
        syncHandoffServers()
        startEventLoopIfNeeded()
    }

    func startPinnedLocalVoiceCall(
        cwd: String,
        model: String?,
        approvalPolicy: String,
        sandboxMode: String?
    ) async throws {
        guard activeVoiceSession == nil else { return }
        let key = try await ensurePinnedLocalVoiceThread(
            cwd: cwd,
            model: model,
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode
        )
        try await startRealtimeVoiceSession(for: key, model: model)
    }

    func startVoiceOnThread(_ key: ThreadKey) async throws {
        if let existing = activeVoiceSession, existing.phase != .error { return }
        if activeVoiceSession != nil { endVoiceSessionImmediately() }
        guard key.serverId == Self.localServerID else {
            throw NSError(
                domain: "Litter",
                code: 3310,
                userInfo: [NSLocalizedDescriptionKey: "Voice is only available on the local server"]
            )
        }
        try await startRealtimeVoiceSession(for: key)
    }

    func stopActiveVoiceSession() async {
        guard let session = activeVoiceSession else { return }
        let key = session.threadKey
        guard voiceStopRequestedThreadKey != key else { return }
        voiceStopRequestedThreadKey = key
        updateVoiceSessionForPendingStop(key)

        guard isServerConnected(key.serverId) else {
            voiceStopRequestedThreadKey = nil
            endVoiceSessionImmediately()
            return
        }

        do {
            _ = try await requireAppModel().rpc.threadRealtimeStop(
                serverId: key.serverId,
                params: ThreadRealtimeStopParams(threadId: key.threadId)
            )
            if voiceStopRequestedThreadKey == key {
                voiceStopRequestedThreadKey = nil
                endVoiceSessionImmediately()
            }
        } catch {
            voiceStopRequestedThreadKey = nil
            failVoiceSession("Failed to hang up: \(error.localizedDescription)")
        }
    }

    func toggleActiveVoiceSessionSpeaker() async throws {
        guard activeVoiceSession != nil else { return }
        try voiceSessionCoordinator.toggleSpeaker()
    }

    private func startEventLoopIfNeeded() {
        guard eventTask == nil else { return }
        updateSubscription = requireAppModel().store.subscribeUpdates()
        eventTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, let subscription = self.updateSubscription {
                do {
                    let event = try await subscription.nextUpdate()
                    await MainActor.run {
                        self.handleUpdate(event)
                    }
                } catch {
                    if Task.isCancelled { break }
                    break
                }
            }
        }
    }

    private func handleUpdate(_ event: AppStoreUpdateRecord) {
        switch event {
        case .realtimeStarted(let key, let notification):
            handleRealtimeStarted(key: key, notification: notification)
        case .realtimeTranscriptUpdated(let key, let update):
            handleRealtimeTranscriptUpdated(key: key, update: update)
        case .realtimeHandoffRequested(let key, let request):
            handleRealtimeHandoffRequested(key: key, request: request)
        case .realtimeSpeechStarted(let key):
            handleRealtimeSpeechStarted(key: key)
        case .realtimeOutputAudioDelta(let key, let notification):
            handleRealtimeOutputAudioDelta(key: key, notification: notification)
        case .realtimeError(let key, let notification):
            handleRealtimeError(key: key, notification: notification)
        case .realtimeClosed(let key, let notification):
            handleRealtimeClosed(key: key, notification: notification)
        default:
            break
        }
    }

    private func ensurePinnedLocalVoiceThread(
        cwd: String,
        model: String?,
        approvalPolicy: String,
        sandboxMode: String?
    ) async throws -> ThreadKey {
        let serverId = try await ensureLocalServerConnected()

        if let storedThreadId = persistedLocalVoiceThreadId() {
            let key = ThreadKey(serverId: serverId, threadId: storedThreadId)
            do {
                _ = try await requireAppModel().rpc.threadResume(
                    serverId: key.serverId,
                    params: AppThreadLaunchConfig(
                        model: model,
                        approvalPolicy: AskForApproval(wireValue: approvalPolicy),
                        sandbox: SandboxMode(wireValue: sandboxMode),
                        developerInstructions: nil,
                        persistExtendedHistory: false
                    ).threadResumeParams(
                        threadId: key.threadId,
                        cwdOverride: preferredVoiceThreadCwd(for: key, fallback: cwd)
                    )
                )
                requireAppModel().store.setActiveThread(key: key)
                await requireAppModel().refreshSnapshot()
                return key
            } catch {
                setPersistedLocalVoiceThreadId(nil)
            }
        }

        let response = try await requireAppModel().rpc.threadStart(
            serverId: serverId,
            params: AppThreadLaunchConfig(
                model: model,
                approvalPolicy: AskForApproval(wireValue: approvalPolicy),
                sandbox: SandboxMode(wireValue: sandboxMode),
                developerInstructions: nil,
                persistExtendedHistory: false
            ).threadStartParams(cwd: preferredVoiceThreadCwd(for: nil, fallback: cwd))
        )
        let key = ThreadKey(serverId: serverId, threadId: response.thread.id)
        requireAppModel().store.setActiveThread(key: key)
        setPersistedLocalVoiceThreadId(key.threadId)
        await requireAppModel().refreshSnapshot()
        return key
    }

    private func ensureLocalServerConnected() async throws -> String {
        if let server = appModel?.snapshot?.serverSnapshot(for: Self.localServerID), server.isConnected {
            return server.serverId
        }
        let serverId = try await requireAppModel().serverBridge.connectLocalServer(
            serverId: Self.localServerID,
            displayName: UIDevice.current.name,
            host: "127.0.0.1",
            port: 0
        )
        await requireAppModel().refreshSnapshot()
        syncHandoffServers()
        return serverId
    }

    private func startRealtimeVoiceSession(
        for key: ThreadKey,
        model: String? = nil
    ) async throws {
        let appModel = requireAppModel()
        syncHandoffServers()
        await cleanupKnownRealtimeVoiceSessions(beforeStartingOn: key)

        var thread = appModel.snapshot?.threadSnapshot(for: key)
        if thread == nil {
            _ = try? await appModel.rpc.threadResume(
                serverId: key.serverId,
                params: AppThreadLaunchConfig(
                    model: model,
                    approvalPolicy: nil,
                    sandbox: nil,
                    developerInstructions: nil,
                    persistExtendedHistory: false
                ).threadResumeParams(threadId: key.threadId, cwdOverride: nil)
            )
            appModel.store.setActiveThread(key: key)
            await appModel.refreshSnapshot()
            thread = appModel.snapshot?.threadSnapshot(for: key)
        }

        guard let thread else {
            throw NSError(
                domain: "Litter",
                code: 3302,
                userInfo: [NSLocalizedDescriptionKey: "Voice mode requires an active server thread"]
            )
        }

        let runtimeSessionId = "litter-voice-\(UUID().uuidString.lowercased())"
        let explicitTitle = thread.info.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let threadTitle = explicitTitle.isEmpty ? thread.resolvedPreview : explicitTitle
        let resolvedModel = thread.resolvedModel
        activeVoiceSession = VoiceSessionState.initial(
            threadKey: key,
            threadTitle: threadTitle,
            model: resolvedModel.isEmpty ? (model ?? "Codex") : resolvedModel
        )
        syncVoiceCallActivity()

        do {
            _ = try await appModel.rpc.threadRealtimeStart(
                serverId: key.serverId,
                params: ThreadRealtimeStartParams(
                    threadId: key.threadId,
                    prompt: realtimePrompt(),
                    sessionId: runtimeSessionId,
                    clientControlledHandoff: true
                )
            )
        } catch {
            _ = try? await appModel.rpc.threadRealtimeStop(
                serverId: key.serverId,
                params: ThreadRealtimeStopParams(threadId: key.threadId)
            )
            failVoiceSession(error.localizedDescription)
            throw error
        }
    }

    private func realtimePrompt() -> String {
        let remoteServers = appModel?.snapshot?.servers
            .filter { !$0.isLocal && $0.isConnected }
            .map { (name: $0.displayName, hostname: $0.host) } ?? []
        return VoiceSessionControl.buildPrompt(remoteServers: remoteServers)
    }

    private func syncHandoffServers() {
        guard let servers = appModel?.snapshot?.servers else { return }
        handoffManager.reset()
        for server in servers {
            handoffManager.registerServer(
                serverId: server.serverId,
                name: server.displayName,
                hostname: server.host,
                isLocal: server.isLocal,
                isConnected: server.isConnected
            )
        }
        handoffManager.setTurnConfig(model: handoffModel, effort: handoffEffort, fastMode: handoffFastMode)
    }

    private var knownRealtimeVoiceThreadKeys: [ThreadKey] {
        var keys = Set<ThreadKey>()
        if let activeKey = activeVoiceSession?.threadKey, !activeKey.threadId.isEmpty {
            keys.insert(activeKey)
        }
        if let stopKey = voiceStopRequestedThreadKey, !stopKey.threadId.isEmpty {
            keys.insert(stopKey)
        }
        if let persistedLocalThreadId = persistedLocalVoiceThreadId(), !persistedLocalThreadId.isEmpty {
            keys.insert(ThreadKey(serverId: Self.localServerID, threadId: persistedLocalThreadId))
        }
        return Array(keys)
    }

    private func cleanupKnownRealtimeVoiceSessions(beforeStartingOn key: ThreadKey? = nil) async {
        for candidate in knownRealtimeVoiceThreadKeys where candidate != key {
            guard isServerConnected(candidate.serverId) else { continue }
            _ = try? await requireAppModel().rpc.threadRealtimeStop(
                serverId: candidate.serverId,
                params: ThreadRealtimeStopParams(threadId: candidate.threadId)
            )
        }
    }

    private func handleRealtimeStarted(key: ThreadKey, notification: ThreadRealtimeStartedNotification) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }
        session.sessionId = notification.sessionId
        session.phase = .listening
        session.isListening = true
        activeVoiceSession = session
        syncVoiceCallActivity()

        do {
            try voiceSessionCoordinator.start { [weak self] chunk in
                guard let self else { return }
                await self.appendRealtimeAudioChunk(chunk, for: key)
            }
        } catch {
            failVoiceSession(error.localizedDescription)
        }
    }

    private func handleRealtimeTranscriptUpdated(key: ThreadKey, update: AppVoiceTranscriptUpdate) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }

        let speaker = voiceSpeakerLabel(update.speaker)
        let entry = VoiceSessionTranscriptEntry(
            id: update.itemId,
            speaker: speaker,
            text: update.text,
            timestamp: existingTranscriptTimestamp(id: update.itemId, in: session) ?? Date()
        )

        if let existingIndex = session.transcriptHistory.firstIndex(where: { $0.id == update.itemId }) {
            session.transcriptHistory[existingIndex] = entry
        } else {
            session.transcriptHistory.append(entry)
        }

        if update.isFinal {
            if session.transcriptLiveMessageID == update.itemId || session.transcriptSpeaker == speaker {
                session.transcriptText = nil
                session.transcriptSpeaker = nil
                session.transcriptLiveMessageID = nil
            }
            if update.speaker == .assistant, !session.isSpeaking {
                session.phase = .thinking
            }
        } else {
            session.transcriptText = update.text
            session.transcriptSpeaker = speaker
            session.transcriptLiveMessageID = update.itemId
            session.phase = voiceSpeakerPhase(update.speaker)
        }

        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func handleRealtimeHandoffRequested(key: ThreadKey, request: AppVoiceHandoffRequest) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }

        session.transcriptText = nil
        session.transcriptSpeaker = nil
        session.transcriptLiveMessageID = nil
        activeVoiceSession = session
        syncVoiceCallActivity()

        syncHandoffServers()
        handoffManager.handleHandoffRequest(
            handoffId: request.handoffId,
            voiceServerId: key.serverId,
            voiceThreadId: key.threadId,
            inputTranscript: request.inputTranscript,
            activeTranscript: request.activeTranscript,
            serverHint: request.serverHint,
            fallbackTranscript: request.fallbackTranscript
        )
        processHandoffActions()
    }

    private func handleRealtimeSpeechStarted(key: ThreadKey) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }
        voiceSessionCoordinator.flushPlayback()
        if session.transcriptSpeaker == "Codex" || session.transcriptSpeaker == nil {
            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
        }
        if session.phase != .error {
            session.phase = .listening
        }
        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func handleRealtimeOutputAudioDelta(key: ThreadKey, notification: ThreadRealtimeOutputAudioDeltaNotification) {
        guard activeVoiceSession?.threadKey == key else { return }
        voiceSessionCoordinator.enqueueOutputAudio(notification.audio)
    }

    private func handleRealtimeError(key: ThreadKey, notification: ThreadRealtimeErrorNotification) {
        guard activeVoiceSession?.threadKey == key else { return }
        if notification.message.contains("active response in progress") {
            return
        }
        failVoiceSession(notification.message)
    }

    private func handleRealtimeClosed(key: ThreadKey, notification: ThreadRealtimeClosedNotification) {
        guard activeVoiceSession?.threadKey == key else { return }

        if var session = activeVoiceSession, session.threadKey == key {
            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
            activeVoiceSession = session
        }

        let reason = notification.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if voiceStopRequestedThreadKey == key || reason == "requested" {
            voiceStopRequestedThreadKey = nil
            endVoiceSessionImmediately()
            return
        }
        failVoiceSession(reason.isEmpty ? "Voice session closed" : reason)
    }

    private func processHandoffActions() {
        let actions = handoffManager.drainActions()
        for action in actions { dispatchSingleHandoffAction(action) }
    }

    private func dispatchSingleHandoffAction(_ action: HandoffAction) {
        switch action {
        case .startThread(let hid, let sid, _, let cwd):
            Task { @MainActor in await self.executeHandoffStartThread(handoffId: hid, serverId: sid, cwd: cwd) }
        case .sendTurn(let hid, let sid, let tid, let transcript, let config):
            Task { @MainActor in await self.executeHandoffSendTurn(handoffId: hid, serverId: sid, threadId: tid, transcript: transcript, model: config.model, effort: config.effort, fastMode: config.fastMode) }
        case .resolveHandoff(let hid, let vtk, let text):
            Task { @MainActor in await self.executeHandoffResolve(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId, text: text) }
        case .finalizeHandoff(let hid, let vtk):
            Task { @MainActor in await self.executeHandoffFinalize(handoffId: hid, voiceServerId: vtk.serverId, voiceThreadId: vtk.threadId) }
        case .setVoicePhase(let phase):
            if var session = activeVoiceSession {
                switch phase {
                case "listening": session.phase = .listening
                case "thinking": session.phase = .thinking
                case "handoff": session.phase = .handoff
                default: break
                }
                activeVoiceSession = session
                syncVoiceCallActivity()
            }
        case .updateHandoffItem, .completeHandoffItem, .error:
            break
        }
    }

    private func executeHandoffStartThread(handoffId: String, serverId: String, cwd: String) async {
        guard let appModel else { return }
        do {
            let response = try await appModel.rpc.threadStart(
                serverId: serverId,
                params: AppThreadLaunchConfig(
                    model: handoffModel,
                    approvalPolicy: nil,
                    sandbox: nil,
                    developerInstructions: nil,
                    persistExtendedHistory: false
                ).threadStartParams(cwd: cwd)
            )
            let key = ThreadKey(serverId: serverId, threadId: response.thread.id)
            appModel.store.setActiveThread(key: key)
            await appModel.refreshSnapshot()
            handoffManager.reportThreadCreated(handoffId: handoffId, serverId: serverId, threadId: key.threadId)
            if var session = activeVoiceSession {
                session.handoffRemoteThreadKey = key
                activeVoiceSession = session
            }
            processHandoffActions()
        } catch {
            handoffManager.reportThreadFailed(handoffId: handoffId, error: error.localizedDescription)
            processHandoffActions()
        }
    }

    private func executeHandoffSendTurn(
        handoffId: String,
        serverId: String,
        threadId: String,
        transcript: String,
        model: String?,
        effort: String?,
        fastMode: Bool
    ) async {
        guard let appModel else { return }
        let key = ThreadKey(serverId: serverId, threadId: threadId)
        do {
            _ = try await appModel.rpc.turnStart(
                serverId: key.serverId,
                params: AppComposerPayload(
                    text: transcript,
                    additionalInputs: [],
                    approvalPolicy: nil,
                    sandboxPolicy: nil,
                    model: model,
                    effort: ReasoningEffort(wireValue: effort),
                    serviceTier: fastMode ? .fast : nil
                ).turnStartParams(threadId: key.threadId)
            )
            handoffManager.reportTurnSent(handoffId: handoffId, baseItemCount: 0)
            startHandoffStreamPolling(handoffId: handoffId, key: key)
            processHandoffActions()
        } catch {
            handoffManager.reportTurnFailed(handoffId: handoffId, error: error.localizedDescription)
            processHandoffActions()
        }
    }

    private func executeHandoffResolve(
        handoffId: String,
        voiceServerId: String,
        voiceThreadId: String,
        text: String
    ) async {
        _ = try? await requireAppModel().rpc.threadRealtimeResolveHandoff(
            serverId: voiceServerId,
            params: ThreadRealtimeResolveHandoffParams(
                threadId: voiceThreadId,
                handoffId: handoffId,
                outputText: text
            )
        )
    }

    private func executeHandoffFinalize(
        handoffId: String,
        voiceServerId: String,
        voiceThreadId: String
    ) async {
        _ = try? await requireAppModel().rpc.threadRealtimeFinalizeHandoff(
            serverId: voiceServerId,
            params: ThreadRealtimeFinalizeHandoffParams(
                threadId: voiceThreadId,
                handoffId: handoffId
            )
        )
        handoffManager.reportFinalized(handoffId: handoffId)
        processHandoffActions()
        if var session = activeVoiceSession {
            session.phase = .listening
            session.handoffRemoteThreadKey = nil
            activeVoiceSession = session
            syncVoiceCallActivity()
        }
    }

    private func startHandoffStreamPolling(handoffId: String, key: ThreadKey) {
        handoffActionPollTask?.cancel()
        handoffActionPollTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard let thread = self.appModel?.snapshot?.threadSnapshot(for: key) else { break }
                let turnActive = thread.activeTurnId != nil || thread.info.status == .active
                let items: [(id: String, text: String)] = thread.hydratedConversationItems.suffix(20).compactMap { item in
                    let conversationItem = item.conversationItem
                    switch conversationItem.content {
                    case .assistant(let data):
                        return (conversationItem.id, data.text)
                    case .commandExecution(let data):
                        return (conversationItem.id, "[cmd] \(data.command.prefix(80)) \(data.status.displayLabel)")
                    case .mcpToolCall(let data):
                        return (conversationItem.id, "[\(data.tool)] \(data.status.displayLabel)")
                    default:
                        return nil
                    }
                }
                self.handoffManager.pollStreamProgress(handoffId: handoffId, items: items, turnActive: turnActive)
                self.processHandoffActions()
                if !turnActive { break }
            }
        }
    }

    private func handleVoiceSessionCoordinatorEvent(_ event: VoiceSessionCoordinator.Event) {
        guard var session = activeVoiceSession else { return }

        switch event {
        case .inputLevel(let level):
            session.inputLevel = level
            session.isListening = true
            if level > 0.05, !session.isSpeaking {
                session.phase = .listening
            }
            activeVoiceSession = session
            syncVoiceCallActivity()

            let token = UUID()
            voiceInputDecayToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard let self,
                      self.voiceInputDecayToken == token,
                      var current = self.activeVoiceSession,
                      current.threadKey == session.threadKey else {
                    return
                }
                current.inputLevel = 0
                if !current.isSpeaking && current.phase != .error {
                    current.phase = .thinking
                }
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .outputLevel(let level):
            session.outputLevel = level
            session.isSpeaking = level > 0.02
            if session.isSpeaking {
                session.phase = .speaking
            }
            activeVoiceSession = session
            syncVoiceCallActivity()

            let token = UUID()
            voiceOutputDecayToken = token
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self,
                      self.voiceOutputDecayToken == token,
                      var current = self.activeVoiceSession,
                      current.threadKey == session.threadKey else {
                    return
                }
                current.outputLevel = 0
                current.isSpeaking = false
                if current.phase != .error {
                    current.phase = .listening
                }
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .routeChanged(let route):
            session.route = route
            activeVoiceSession = session
            syncVoiceCallActivity()

        case .interrupted:
            session.phase = .thinking
            activeVoiceSession = session
            syncVoiceCallActivity()

        case .failure(let message):
            failVoiceSession(message)
        }
    }

    private func appendRealtimeAudioChunk(_ chunk: ThreadRealtimeAudioChunk, for key: ThreadKey) async {
        guard activeVoiceSession?.threadKey == key, isServerConnected(key.serverId) else { return }
        do {
            _ = try await requireAppModel().rpc.threadRealtimeAppendAudio(
                serverId: key.serverId,
                params: ThreadRealtimeAppendAudioParams(threadId: key.threadId, audio: chunk)
            )
        } catch {
            failVoiceSession(error.localizedDescription)
        }
    }

    private func failVoiceSession(_ message: String) {
        voiceSessionCoordinator.stop()
        voiceInputDecayToken = nil
        voiceOutputDecayToken = nil

        guard var session = activeVoiceSession else {
            endVoiceSessionImmediately()
            return
        }

        session.phase = .error
        session.lastError = message
        session.isListening = false
        session.isSpeaking = false
        session.inputLevel = 0
        session.outputLevel = 0
        session.transcriptLiveMessageID = nil
        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func endVoiceSessionImmediately() {
        let activeKey = activeVoiceSession?.threadKey
        voiceInputDecayToken = nil
        voiceOutputDecayToken = nil
        voiceStopRequestedThreadKey = nil
        voiceSessionCoordinator.stop()
        _ = activeKey
        activeVoiceSession = nil
        endVoiceCallActivity()
    }

    private func updateVoiceSessionForPendingStop(_ key: ThreadKey) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }
        session.phase = .thinking
        session.isListening = false
        session.isSpeaking = false
        session.inputLevel = 0
        session.outputLevel = 0
        session.transcriptSpeaker = "System"
        session.transcriptText = "Hanging up..."
        session.lastError = nil
        activeVoiceSession = session
        syncVoiceCallActivity()
    }

    private func syncVoiceCallActivity() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let session = activeVoiceSession else {
            endVoiceCallActivity()
            return
        }
        if voiceCallActivity == nil {
            let attributes = CodexVoiceCallAttributes(
                threadId: session.threadKey.threadId,
                threadTitle: session.threadTitle,
                model: session.model,
                startDate: session.startedAt
            )
            do {
                voiceCallActivity = try Activity.request(
                    attributes: attributes,
                    content: .init(state: session.activityContentState, staleDate: nil)
                )
            } catch {}
            return
        }
        guard let activity = voiceCallActivity else { return }
        Task {
            await activity.update(
                .init(state: session.activityContentState, staleDate: Date(timeIntervalSinceNow: 120))
            )
        }
    }

    private func endVoiceCallActivity() {
        guard let activity = voiceCallActivity else { return }
        Task {
            await activity.end(nil, dismissalPolicy: .after(.now + 2))
        }
        voiceCallActivity = nil
    }

    private func requireAppModel() -> AppModel {
        guard let appModel else {
            fatalError("VoiceRuntimeController used before binding AppModel")
        }
        return appModel
    }

    private func isServerConnected(_ serverId: String) -> Bool {
        appModel?.snapshot?.serverSnapshot(for: serverId)?.isConnected == true
    }

    private func persistedLocalVoiceThreadId() -> String? {
        let stored = UserDefaults.standard.string(forKey: Self.persistedLocalVoiceThreadIDKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? nil : stored
    }

    private func setPersistedLocalVoiceThreadId(_ threadId: String?) {
        let trimmed = threadId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.persistedLocalVoiceThreadIDKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: Self.persistedLocalVoiceThreadIDKey)
        }
    }

    private func preferredVoiceThreadCwd(for key: ThreadKey?, fallback: String) -> String {
        let existingCwd = key.flatMap {
            appModel?.snapshot?.threadSnapshot(for: $0)?.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        } ?? ""
        if !existingCwd.isEmpty {
            return existingCwd
        }
        let trimmedFallback = fallback.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedFallback.isEmpty {
            return trimmedFallback
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    }

    private func installVoiceSessionControlObserver() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        let callback: CFNotificationCallback = { _, observer, _, _, _ in
            guard let observer else { return }
            let controller = Unmanaged<VoiceRuntimeController>.fromOpaque(observer).takeUnretainedValue()
            Task { @MainActor in
                controller.handlePendingVoiceSessionEndRequestIfNeeded()
            }
        }
        CFNotificationCenterAddObserver(
            center,
            observer,
            callback,
            VoiceSessionControl.endRequestDarwinNotification as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handlePendingVoiceSessionEndRequestIfNeeded() {
        guard let token = VoiceSessionControl.pendingEndRequestToken(after: lastHandledVoiceEndRequestToken) else {
            return
        }
        lastHandledVoiceEndRequestToken = token
        Task { await stopActiveVoiceSession() }
    }
}

private extension VoiceRuntimeController {
    func voiceSpeakerLabel(_ speaker: AppVoiceSpeaker) -> String {
        switch speaker {
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        }
    }

    func voiceSpeakerPhase(_ speaker: AppVoiceSpeaker) -> VoiceSessionPhase {
        switch speaker {
        case .user:
            return .listening
        case .assistant:
            return .speaking
        }
    }

    func existingTranscriptTimestamp(id: String, in session: VoiceSessionState) -> Date? {
        session.transcriptHistory.first(where: { $0.id == id })?.timestamp
    }
}
