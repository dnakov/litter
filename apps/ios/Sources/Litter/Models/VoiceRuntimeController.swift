import ActivityKit
import AVFoundation
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
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) async throws {
        if let existing = activeVoiceSession, existing.phase != .error { return }
        if activeVoiceSession != nil { endVoiceSessionImmediately() }
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
            _ = try await requireAppModel().client.stopRealtimeSession(
                serverId: key.serverId,
                params: AppStopRealtimeSessionRequest(threadId: key.threadId)
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
        case .fullResync, .voiceSessionChanged:
            guard let key = activeVoiceSession?.threadKey else { return }
            // Realtime start/close updates can coalesce into FullResync, so
            // voice must reconcile from the shared snapshot rather than rely
            // on the dedicated RealtimeStarted/RealtimeClosed events alone.
            scheduleSharedVoiceSessionSync(for: key)
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
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) async throws -> ThreadKey {
        let appModel = requireAppModel()
        let serverId = try await ensureLocalServerConnected()

        if let storedThreadId = persistedLocalVoiceThreadId() {
            let key = ThreadKey(serverId: serverId, threadId: storedThreadId)
            if let resolvedKey = await appModel.ensureThreadLoaded(key: key),
               let thread = appModel.threadSnapshot(for: resolvedKey),
               pinnedVoiceThreadMatchesRequestedConfig(
                   thread,
                   cwd: cwd,
                   model: model,
                   approvalPolicy: approvalPolicy,
                   sandboxMode: sandboxMode
               ) {
                appModel.store.setActiveThread(key: resolvedKey)
                await appModel.refreshSnapshot()
                return resolvedKey
            } else {
                setPersistedLocalVoiceThreadId(nil)
            }
        }

        let key = try await appModel.client.startThread(
            serverId: serverId,
            params: AppThreadLaunchConfig(
                model: model,
                approvalPolicy: approvalPolicy,
                sandbox: sandboxMode,
                developerInstructions: nil,
                persistExtendedHistory: true
            ).threadStartRequest(cwd: preferredVoiceThreadCwd(for: nil, fallback: cwd))
        )
        SavedThreadsStore.add(.init(threadKey: key))
        appModel.store.setActiveThread(key: key)
        setPersistedLocalVoiceThreadId(key.threadId)
        await appModel.refreshSnapshot()
        return key
    }

    private func ensureLocalServerConnected() async throws -> String {
        if let server = appModel?.snapshot?.serverSnapshot(for: Self.localServerID), server.isConnected {
            return server.serverId
        }
        let serverId = try await requireAppModel().serverBridge.connectLocalServer(
            serverId: Self.localServerID,
            displayName: requireAppModel().resolvedLocalServerDisplayName(),
            host: "127.0.0.1",
            port: 0
        )
        await requireAppModel().restoreStoredLocalChatGPTAuth(serverId: serverId)
        await requireAppModel().refreshSnapshot()
        syncHandoffServers()
        return serverId
    }

    private func startRealtimeVoiceSession(
        for key: ThreadKey,
        model: String? = nil
    ) async throws {
        // Request microphone permission before starting the realtime session.
        // Without permission the audio engine cannot capture input, and the
        // server-side realtime session may hang waiting for audio frames.
        let micGranted = await AVAudioApplication.requestRecordPermission()
        guard micGranted else {
            throw NSError(
                domain: "Litter",
                code: 3311,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is required for voice mode"]
            )
        }

        let appModel = requireAppModel()
        syncHandoffServers()
        await cleanupKnownRealtimeVoiceSessions(beforeStartingOn: key)

        var resolvedKey = key
        var thread = appModel.snapshot?.threadSnapshot(for: key)
        if thread == nil {
            if let loadedKey = await appModel.ensureThreadLoaded(key: key) {
                resolvedKey = loadedKey
                thread = appModel.threadSnapshot(for: loadedKey)
            }
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
            threadKey: resolvedKey,
            threadTitle: threadTitle,
            model: resolvedModel.isEmpty ? (model ?? "Codex") : resolvedModel
        )
        syncVoiceCallActivity()

        do {
            let dynamicTools = try CrossServerTools.buildDynamicToolSpecs().map { try $0.rpcSpec() }
            _ = try await appModel.client.startRealtimeSession(
                serverId: resolvedKey.serverId,
                params: AppStartRealtimeSessionRequest(
                    threadId: resolvedKey.threadId,
                    prompt: realtimePrompt(),
                    sessionId: runtimeSessionId,
                    clientControlledHandoff: true,
                    dynamicTools: dynamicTools
                )
            )
        } catch {
            _ = try? await appModel.client.stopRealtimeSession(
                serverId: key.serverId,
                params: AppStopRealtimeSessionRequest(threadId: key.threadId)
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
            _ = try? await requireAppModel().client.stopRealtimeSession(
                serverId: candidate.serverId,
                params: AppStopRealtimeSessionRequest(threadId: candidate.threadId)
            )
        }
    }

    private func handleRealtimeStarted(key: ThreadKey, notification: AppRealtimeStartedNotification) {
        guard var session = activeVoiceSession, session.threadKey == key else { return }
        session.sessionId = notification.sessionId
        session.phase = .listening
        session.isListening = true
        activeVoiceSession = session

        startVoiceSessionCoordinatorIfNeeded(for: key)
        scheduleSharedVoiceSessionSync(for: key)
    }

    private func handleRealtimeTranscriptUpdated(key: ThreadKey, update: AppVoiceTranscriptUpdate) {
        guard activeVoiceSession?.threadKey == key else { return }
        scheduleSharedVoiceSessionSync(for: key)
    }

    private func handleRealtimeHandoffRequested(key: ThreadKey, request: AppVoiceHandoffRequest) {
        guard activeVoiceSession?.threadKey == key else { return }

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
        scheduleSharedVoiceSessionSync(for: key)
    }

    private func handleRealtimeSpeechStarted(key: ThreadKey) {
        guard activeVoiceSession?.threadKey == key else { return }
        voiceSessionCoordinator.flushPlayback()
        scheduleSharedVoiceSessionSync(for: key)
    }

    private func handleRealtimeOutputAudioDelta(key: ThreadKey, notification: AppRealtimeOutputAudioDeltaNotification) {
        guard activeVoiceSession?.threadKey == key else { return }
        voiceSessionCoordinator.enqueueOutputAudio(notification.audio)
    }

    private func handleRealtimeError(key: ThreadKey, notification: AppRealtimeErrorNotification) {
        guard activeVoiceSession?.threadKey == key else { return }
        // Ignore transient "active response in progress" errors — they don't
        // indicate a broken session.
        if notification.message.contains("active response in progress") {
            return
        }
        failVoiceSession(notification.message)
    }

    private func handleRealtimeClosed(key: ThreadKey, notification: AppRealtimeClosedNotification) {
        guard activeVoiceSession?.threadKey == key else { return }

        let reason = notification.reason?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let userRequested = voiceStopRequestedThreadKey == key

        // User-initiated stop: clean end, even if the session was already in
        // an error state.
        if userRequested {
            voiceStopRequestedThreadKey = nil
            endVoiceSessionImmediately()
            return
        }

        // Close arriving after a RealtimeError carries reason="requested"
        // because the server auto-closes the broken session. Keep the
        // session alive in its error state so the user can see what went
        // wrong and dismiss via the End button.
        if activeVoiceSession?.phase == .error {
            return
        }

        if reason == "requested" {
            endVoiceSessionImmediately()
            return
        }

        // Unexpected close — end the session with an error so the UI doesn't
        // get stuck in a stale "Listening" / "Speaking" state.
        let message = reason.isEmpty ? "Voice session closed unexpectedly" : "Voice session closed: \(reason)"
        failVoiceSession(message)
    }

    private func startVoiceSessionCoordinatorIfNeeded(for key: ThreadKey) {
        guard activeVoiceSession?.threadKey == key else { return }
        guard !voiceSessionCoordinator.isRunning else { return }

        do {
            try voiceSessionCoordinator.start { [weak self] chunk in
                guard let self else { return }
                await self.appendRealtimeAudioChunk(chunk, for: key)
            }
        } catch {
            failVoiceSession(error.localizedDescription)
        }
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
            let key = try await appModel.client.startThread(
                serverId: serverId,
                params: AppThreadLaunchConfig(
                    model: handoffModel,
                    approvalPolicy: nil,
                    sandbox: nil,
                    developerInstructions: nil,
                    persistExtendedHistory: true
                ).threadStartRequest(cwd: cwd)
            )
            SavedThreadsStore.add(.init(threadKey: key))
            appModel.store.setActiveThread(key: key)
            await appModel.refreshSnapshot()
            handoffManager.reportThreadCreated(handoffId: handoffId, serverId: serverId, threadId: key.threadId)
            appModel.store.setVoiceHandoffThread(key: key)
            await syncSharedVoiceSessionFromStore(for: activeVoiceSession?.threadKey)
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
            try await appModel.startTurn(
                key: key,
                payload: AppComposerPayload(
                    text: transcript,
                    additionalInputs: [],
                    approvalPolicy: nil,
                    sandboxPolicy: nil,
                    model: model,
                    effort: ReasoningEffort(wireValue: effort),
                    serviceTier: fastMode ? .fast : nil
                )
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
        _ = handoffId
        _ = try? await requireAppModel().client.resolveRealtimeHandoff(
            serverId: voiceServerId,
            params: AppResolveRealtimeHandoffRequest(
                threadId: voiceThreadId,
                toolCallOutput: text
            )
        )
        processHandoffActions()
    }

    private func executeHandoffFinalize(
        handoffId: String,
        voiceServerId: String,
        voiceThreadId: String
    ) async {
        _ = try? await requireAppModel().client.finalizeRealtimeHandoff(
            serverId: voiceServerId,
            params: AppFinalizeRealtimeHandoffRequest(
                threadId: voiceThreadId
            )
        )
        handoffManager.reportFinalized(handoffId: handoffId)
        requireAppModel().store.setVoiceHandoffThread(key: nil)
        await syncSharedVoiceSessionFromStore(for: activeVoiceSession?.threadKey)
        processHandoffActions()
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
                    case .codeReview(let data):
                        guard let first = data.findings.first else { return nil }
                        return (conversationItem.id, "[review] \(first.title)")
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
                current.isListening = false
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .outputLevel(let level):
            session.outputLevel = level
            session.isSpeaking = level > 0.02
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
                self.activeVoiceSession = current
                self.syncVoiceCallActivity()
            }

        case .routeChanged(let route):
            session.route = route
            activeVoiceSession = session
            syncVoiceCallActivity()

        case .interrupted:
            break

        case .failure(let message):
            failVoiceSession(message)
        }
    }

    private func appendRealtimeAudioChunk(_ chunk: AppRealtimeAudioChunk, for key: ThreadKey) async {
        guard activeVoiceSession?.threadKey == key, isServerConnected(key.serverId) else { return }
        do {
            _ = try await requireAppModel().client.appendRealtimeAudio(
                serverId: key.serverId,
                params: AppAppendRealtimeAudioRequest(threadId: key.threadId, audio: chunk)
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

    private func pinnedVoiceThreadMatchesRequestedConfig(
        _ thread: AppThreadSnapshot,
        cwd: String,
        model: String?,
        approvalPolicy: AppAskForApproval?,
        sandboxMode: AppSandboxMode?
    ) -> Bool {
        let requestedCwd = preferredVoiceThreadCwd(for: thread.key, fallback: cwd)
        let existingCwd = thread.info.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requestedCwd.isEmpty, requestedCwd != existingCwd {
            return false
        }

        let requestedModel = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let existingModel = (thread.model ?? thread.info.model)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !requestedModel.isEmpty, requestedModel != existingModel {
            return false
        }
        if let approvalPolicy, approvalPolicy != thread.effectiveApprovalPolicy {
            return false
        }
        if let sandboxMode, sandboxMode != thread.effectiveSandboxPolicy?.launchOverrideMode {
            return false
        }
        return true
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

    private func scheduleSharedVoiceSessionSync(for key: ThreadKey?) {
        Task { @MainActor [weak self] in
            await self?.syncSharedVoiceSessionFromStore(for: key)
        }
    }

    private func syncSharedVoiceSessionFromStore(for key: ThreadKey?) async {
        guard let appModel else { return }
        let expectedKey = key ?? activeVoiceSession?.threadKey
        await appModel.refreshSnapshot()
        guard var session = activeVoiceSession else { return }
        guard expectedKey == nil || session.threadKey == expectedKey else { return }

        let shared = appModel.snapshot?.voiceSession
        if shared?.activeThread == session.threadKey || shared?.phase == .error {
            applySharedVoiceSession(shared, to: &session)
            activeVoiceSession = session
            syncVoiceCallActivity()
            if shared?.activeThread == session.threadKey,
               session.sessionId?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                startVoiceSessionCoordinatorIfNeeded(for: session.threadKey)
            }
            return
        }

        // Keep waiting while the local session is still optimistically
        // connecting. Once the shared store has shown a live/error session,
        // a later FullResync with no active voice means the session is over.
        if session.phase != .connecting {
            endVoiceSessionImmediately()
        }
    }
}

private extension VoiceRuntimeController {
    func applySharedVoiceSession(_ shared: AppVoiceSessionSnapshot?, to session: inout VoiceSessionState) {
        session.sessionId = shared?.sessionId
        session.phase = shared?.phase.map(voiceSessionPhase) ?? .connecting
        session.lastError = shared?.lastError
        session.handoffRemoteThreadKey = shared?.handoffThreadKey
        switch session.phase {
        case .listening:
            session.isListening = true
            session.isSpeaking = false
        case .speaking:
            session.isListening = false
            session.isSpeaking = true
        case .connecting, .thinking, .handoff, .error:
            session.isListening = false
            session.isSpeaking = false
        }

        let entries = (shared?.transcriptEntries ?? []).map {
            VoiceSessionTranscriptEntry(
                id: $0.itemId,
                speaker: voiceSpeakerLabel($0.speaker),
                text: $0.text,
                timestamp: existingTranscriptTimestamp(id: $0.itemId, in: session) ?? Date()
            )
        }
        session.transcriptHistory = entries.filter {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if let last = session.transcriptHistory.last {
            session.transcriptText = last.text
            session.transcriptSpeaker = last.speaker
            session.transcriptLiveMessageID = last.id
        } else {
            session.transcriptText = nil
            session.transcriptSpeaker = nil
            session.transcriptLiveMessageID = nil
        }
    }

    func voiceSessionPhase(_ phase: AppVoiceSessionPhase) -> VoiceSessionPhase {
        switch phase {
        case .connecting:
            return .connecting
        case .listening:
            return .listening
        case .speaking:
            return .speaking
        case .thinking:
            return .thinking
        case .handoff:
            return .handoff
        case .error:
            return .error
        }
    }

    func voiceSpeakerLabel(_ speaker: AppVoiceSpeaker) -> String {
        switch speaker {
        case .user:
            return "You"
        case .assistant:
            return "Codex"
        }
    }

    func existingTranscriptTimestamp(id: String, in session: VoiceSessionState) -> Date? {
        session.transcriptHistory.first(where: { $0.id == id })?.timestamp
    }
}
