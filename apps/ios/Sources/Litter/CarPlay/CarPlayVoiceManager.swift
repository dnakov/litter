import CarPlay
import MediaPlayer
import UIKit

@MainActor
final class CarPlayVoiceManager {
    private let voiceActions: VoiceActions
    private let appModel: AppModel
    private weak var interfaceController: CPInterfaceController?

    private var voiceTabTemplate: CPGridTemplate?
    private var sessionsTabTemplate: CPListTemplate?
    private var transcriptTemplate: CPListTemplate?
    private var sessionTranscriptTemplate: CPListTemplate?
    private var sessionTranscriptKey: ThreadKey?
    private var lastSessionTranscriptSig: String?

    private var observationTask: Task<Void, Error>?
    private var lastPhase: VoiceSessionPhase?
    private var lastTranscriptHistoryID: String?
    private var lastTranscriptLive: String?
    private var lastSessionsSignature: String?
    private var isShowingNowPlaying = false
    private var isShowingTranscript = false

    init(voiceActions: VoiceActions, appModel: AppModel, interfaceController: CPInterfaceController) {
        self.voiceActions = voiceActions
        self.appModel = appModel
        self.interfaceController = interfaceController
    }

    // MARK: - Tab Templates

    func buildVoiceTab() -> CPGridTemplate {
        let template = CPGridTemplate(title: "Voice", gridButtons: voiceGridButtons())
        template.tabImage = UIImage(systemName: "waveform")
        template.tabTitle = "Voice"
        voiceTabTemplate = template
        return template
    }

    func buildSessionsTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: "Sessions",
            sections: [sessionsSection()]
        )
        template.tabImage = UIImage(systemName: "list.bullet")
        template.tabTitle = "Sessions"
        template.emptyViewTitleVariants = ["No recent sessions"]
        template.emptyViewSubtitleVariants = ["Start a voice session to see it here"]
        sessionsTabTemplate = template
        return template
    }

    // MARK: - Observation

    func startObserving() {
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard let self else { break }
                await self.tick()
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    private func tick() async {
        refreshSessionsIfNeeded()
        refreshSessionTranscriptIfNeeded()
        await refreshActiveSessionIfNeeded()
    }

    // MARK: - Voice Tab (Grid)

    private func voiceGridButtons() -> [CPGridButton] {
        let session = voiceActions.activeVoiceSession
        let phase = session?.phase
        var buttons: [CPGridButton] = []

        // Primary: Tap to Talk / End
        if let phase {
            buttons.append(makeGridButton(
                titles: [primaryActionLabel(for: phase)],
                systemImage: phase == .error ? "mic.fill" : "stop.fill"
            ) { [weak self] _ in
                self?.handleEnd()
            })
        } else {
            buttons.append(makeGridButton(
                titles: ["Tap to Talk"],
                systemImage: "mic.fill"
            ) { [weak self] _ in
                self?.handleStart()
            })
        }

        // Continue last session (visible when no active voice session but a recent one exists)
        if session == nil, let recent = mostRecentResumable() {
            buttons.append(makeGridButton(
                titles: ["Continue", String(recent.displayTitle.prefix(24))],
                systemImage: "arrow.uturn.backward.circle.fill"
            ) { [weak self] _ in
                self?.handleResume(recent.key)
            })
        }

        // Sessions shortcut
        buttons.append(makeGridButton(
            titles: ["Sessions"],
            systemImage: "list.bullet.rectangle.portrait"
        ) { [weak self] _ in
            self?.openSessionsTab()
        })

        // Transcript (only meaningful during an active session)
        if session != nil {
            buttons.append(makeGridButton(
                titles: ["Transcript"],
                systemImage: "text.bubble.fill"
            ) { [weak self] _ in
                self?.openActiveSession()
            })
        }

        return buttons
    }

    private func primaryActionLabel(for phase: VoiceSessionPhase) -> String {
        switch phase {
        case .connecting: return "Cancel"
        case .listening:  return "Stop"
        case .thinking, .handoff: return "Interrupt"
        case .speaking:   return "Done"
        case .error:      return "Tap to Talk"
        }
    }

    private func makeGridButton(
        titles: [String],
        systemImage: String,
        handler: @escaping (CPGridButton) -> Void
    ) -> CPGridButton {
        let image = UIImage(systemName: systemImage,
                            withConfiguration: UIImage.SymbolConfiguration(pointSize: 48, weight: .semibold))
            ?? UIImage()
        return CPGridButton(titleVariants: titles, image: image, handler: handler)
    }

    private func refreshVoiceTab() {
        voiceTabTemplate?.updateGridButtons(voiceGridButtons())
    }

    // MARK: - Sessions Tab

    private func sessionsSection() -> CPListSection {
        let sorted = (appModel.snapshot?.sessionSummaries ?? [])
            .filter { !$0.isSubagent }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .prefix(12)

        var items: [CPListItem] = []
        let activeKey = voiceActions.activeVoiceSession?.threadKey

        for summary in sorted {
            items.append(makeSessionItem(summary, isActive: summary.key == activeKey))
        }
        if items.isEmpty {
            let placeholder = CPListItem(
                text: "No recent sessions",
                detailText: "Start a voice session from the Voice tab",
                image: UIImage(systemName: "waveform")
            )
            items.append(placeholder)
        }
        return CPListSection(items: items)
    }

    private func makeSessionItem(_ summary: AppSessionSummary, isActive: Bool) -> CPListItem {
        let title = String(summary.displayTitle.prefix(60))
        let detail = sessionDetail(summary, isActive: isActive)
        let image = UIImage(systemName: sessionStateSymbol(summary, isActive: isActive))
        let item = CPListItem(text: title, detailText: detail, image: image)
        if isActive || summary.hasActiveTurn {
            item.isPlaying = true
            item.playingIndicatorLocation = .trailing
        }
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.openSessionTranscript(summary)
            completion()
        }
        return item
    }

    // MARK: - Session Transcript (pushed when a session row is tapped)

    private func openSessionTranscript(_ summary: AppSessionSummary) {
        let template = buildSessionTranscriptTemplate(summary)
        sessionTranscriptTemplate = template
        sessionTranscriptKey = summary.key
        lastSessionTranscriptSig = transcriptSignature(for: summary.key)
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func transcriptSignature(for key: ThreadKey) -> String {
        let items = appModel.threadSnapshot(for: key)?.hydratedConversationItems ?? []
        // id + renderDigest (via content hash proxy) is enough to diff turn changes
        return items.suffix(30)
            .map { "\($0.id)|\($0.content.hashValue)" }
            .joined(separator: ";")
    }

    private func refreshSessionTranscriptIfNeeded() {
        guard let key = sessionTranscriptKey,
              let template = sessionTranscriptTemplate,
              let ic = interfaceController else { return }

        // If the user popped the template, clear refs.
        let isStillPushed = ic.templates.contains(where: { $0 === template })
        if !isStillPushed {
            sessionTranscriptTemplate = nil
            sessionTranscriptKey = nil
            lastSessionTranscriptSig = nil
            return
        }

        let sig = transcriptSignature(for: key)
        guard sig != lastSessionTranscriptSig else { return }
        lastSessionTranscriptSig = sig

        guard let summary = appModel.snapshot?.sessionSummaries.first(where: { $0.key == key }) else { return }
        template.updateSections([sessionTranscriptSection(for: summary)])
    }

    private func buildSessionTranscriptTemplate(_ summary: AppSessionSummary) -> CPListTemplate {
        let title = String(summary.displayTitle.prefix(40))
        let template = CPListTemplate(
            title: title,
            sections: [sessionTranscriptSection(for: summary)]
        )
        // Only local sessions can be resumed as voice — hide the mic for remote.
        if summary.key.serverId == VoiceRuntimeController.localServerID {
            let voiceButton = CPBarButton(image: UIImage(systemName: "mic.fill") ?? UIImage()) { [weak self] _ in
                self?.handleResume(summary.key)
            }
            template.trailingNavigationBarButtons = [voiceButton]
        }
        return template
    }

    private func sessionTranscriptSection(for summary: AppSessionSummary) -> CPListSection {
        let thread = appModel.threadSnapshot(for: summary.key)
        let items = (thread?.hydratedConversationItems ?? [])
            .suffix(30) // most recent turns
            .compactMap { transcriptRow(for: $0) }
        if items.isEmpty {
            let empty = CPListItem(
                text: "No messages yet",
                detailText: "Tap the mic to start speaking",
                image: UIImage(systemName: "text.bubble")
            )
            return CPListSection(items: [empty])
        }
        return CPListSection(items: Array(items.reversed()))
    }

    private func transcriptRow(for item: HydratedConversationItem) -> CPListItem? {
        switch item.content {
        case .user(let data):
            return messageRow(role: "YOU", body: data.text)
        case .assistant(let data):
            return messageRow(role: "CODEX", body: data.text)
        case .reasoning(let data):
            let body = data.summary.first ?? data.content.first ?? ""
            return messageRow(role: "REASONING", body: body)
        case .commandExecution(let data):
            return messageRow(role: "COMMAND", body: data.command)
        case .fileChange(let data):
            let firstPath = data.changes.first?.path ?? ""
            let extra = data.changes.count > 1 ? " +\(data.changes.count - 1) more" : ""
            return messageRow(role: "EDIT", body: firstPath + extra)
        case .mcpToolCall(let data):
            return messageRow(role: "TOOL", body: "\(data.server) · \(data.tool)")
        case .dynamicToolCall(let data):
            return messageRow(role: "TOOL", body: data.tool)
        case .webSearch(let data):
            return messageRow(role: "SEARCH", body: data.query)
        case .error(let data):
            return messageRow(role: "ERROR", body: data.message)
        default:
            return nil
        }
    }

    /// Splits a message across a row's two single-line fields:
    ///   - If it fits in one line, `text` carries the body and `detailText` is the role label.
    ///   - If it overflows, `text` gets the first chunk and `detailText` gets the
    ///     continuation prefixed with the role. Role is never lost.
    private func messageRow(role: String, body: String) -> CPListItem? {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let mainCap = 110
        if trimmed.count <= mainCap {
            return CPListItem(text: trimmed, detailText: role)
        }
        let splitIdx = trimmed.index(trimmed.startIndex, offsetBy: mainCap)
        let main = String(trimmed[..<splitIdx])
        let remainder = String(trimmed[splitIdx...])
        let detailCap = 120 - role.count - 3 // "ROLE · "
        let remainderText: String
        if remainder.count <= detailCap {
            remainderText = remainder
        } else {
            let end = remainder.index(remainder.startIndex, offsetBy: detailCap - 1)
            remainderText = String(remainder[..<end]) + "…"
        }
        return CPListItem(text: main, detailText: "\(role) · \(remainderText)")
    }

    private func sessionDetail(_ summary: AppSessionSummary, isActive: Bool) -> String {
        let server = summary.key.serverId == VoiceRuntimeController.localServerID
            ? "local"
            : summary.serverDisplayName
        let modelLabel = summary.sessionModelLabel ?? summary.model
        let state: String = {
            if isActive { return "now" }
            if summary.hasActiveTurn { return "working" }
            if let updated = summary.updatedAt {
                return relativeTime(fromEpoch: updated)
            }
            return "idle"
        }()
        var parts = [server]
        if !modelLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parts.append(modelLabel)
        }
        parts.append(state)
        return parts.joined(separator: " · ")
    }

    private func sessionStateSymbol(_ summary: AppSessionSummary, isActive: Bool) -> String {
        if isActive { return "waveform.circle.fill" }
        if summary.hasActiveTurn { return "circle.hexagongrid.circle.fill" }
        if summary.key.serverId == VoiceRuntimeController.localServerID {
            return "laptopcomputer"
        }
        return "server.rack"
    }

    private func sessionsSignature() -> String {
        let active = voiceActions.activeVoiceSession?.threadKey
        let summaries = (appModel.snapshot?.sessionSummaries ?? [])
            .filter { !$0.isSubagent }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .prefix(12)
        let parts = summaries.map { s -> String in
            let isActive = s.key == active
            return "\(s.key.serverId)|\(s.key.threadId)|\(s.updatedAt ?? 0)|\(s.hasActiveTurn ? 1 : 0)|\(isActive ? 1 : 0)|\(s.displayTitle.prefix(40))"
        }
        return parts.joined(separator: ";")
    }

    private func refreshSessionsIfNeeded() {
        let sig = sessionsSignature()
        guard sig != lastSessionsSignature else { return }
        lastSessionsSignature = sig
        sessionsTabTemplate?.updateSections([sessionsSection()])
    }

    // MARK: - Active Session (CPNowPlayingTemplate immersive view)

    private func configureNowPlayingTemplate(_ session: VoiceSessionState) {
        let template = CPNowPlayingTemplate.shared
        template.isUpNextButtonEnabled = false
        template.isAlbumArtistButtonEnabled = false
        template.updateNowPlayingButtons(nowPlayingButtons(session))
    }

    private func nowPlayingButtons(_ session: VoiceSessionState) -> [CPNowPlayingButton] {
        let transcriptImg = UIImage(systemName: "text.bubble.fill") ?? UIImage()
        let endImg = UIImage(systemName: "xmark.circle.fill") ?? UIImage()
        let speakerImg = UIImage(systemName: session.route.iconName) ?? UIImage()

        let transcriptBtn = CPNowPlayingImageButton(image: transcriptImg) { [weak self] _ in
            self?.openTranscript()
        }
        let speakerBtn = CPNowPlayingImageButton(image: speakerImg) { [weak self] _ in
            Task { try? await self?.voiceActions.toggleActiveVoiceSessionSpeaker() }
        }
        let endBtn = CPNowPlayingImageButton(image: endImg) { [weak self] _ in
            Task { await self?.voiceActions.stopActiveVoiceSession() }
        }
        return [transcriptBtn, speakerBtn, endBtn]
    }

    private func updateNowPlayingInfo(_ session: VoiceSessionState) {
        let center = MPNowPlayingInfoCenter.default()
        var info = center.nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = session.phase.displayTitle
        info[MPMediaItemPropertyArtist] = session.threadTitle
        let sub = [session.model, session.route.label]
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .joined(separator: " · ")
        info[MPMediaItemPropertyAlbumTitle] = sub
        info[MPNowPlayingInfoPropertyIsLiveStream] = true
        info[MPNowPlayingInfoPropertyPlaybackRate] = 1.0
        center.nowPlayingInfo = info
        center.playbackState = .playing
    }

    private func clearNowPlayingInfo() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    // MARK: - Transcript (pushed on top of CPNowPlayingTemplate)

    private func buildTranscriptTemplate(_ session: VoiceSessionState) -> CPListTemplate {
        let template = CPListTemplate(
            title: session.phase.displayTitle,
            sections: transcriptSections(session)
        )
        let end = CPBarButton(image: UIImage(systemName: "xmark.circle.fill") ?? UIImage()) { [weak self] _ in
            Task { await self?.voiceActions.stopActiveVoiceSession() }
        }
        template.trailingNavigationBarButtons = [end]
        return template
    }

    private func transcriptSections(_ session: VoiceSessionState) -> [CPListSection] {
        // Status row — phase + route, glanceable.
        let statusItem = CPListItem(
            text: session.phase.displayTitle,
            detailText: "\(session.model) · \(session.route.label)",
            image: UIImage(systemName: activePhaseSymbol(session.phase))
        )
        if session.phase == .listening || session.phase == .thinking
            || session.phase == .speaking || session.phase == .handoff {
            statusItem.isPlaying = true
            statusItem.playingIndicatorLocation = .leading
        }
        let statusSection = CPListSection(
            items: [statusItem],
            header: "status",
            sectionIndexTitle: nil
        )

        // Transcript — recent turns.
        let turns = session.transcriptHistory.suffix(6).reversed()
        var transcriptItems: [CPListItem] = []
        for entry in turns {
            let text = truncate(entry.text, max: 110)
            let item = CPListItem(text: text, detailText: entry.speaker.uppercased())
            transcriptItems.append(item)
        }
        // Live in-flight turn
        if let live = session.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !live.isEmpty {
            let speaker = (session.transcriptSpeaker?.uppercased() ?? "…")
            let item = CPListItem(text: truncate(live, max: 110), detailText: speaker + " · live")
            item.isPlaying = true
            item.playingIndicatorLocation = .leading
            transcriptItems.insert(item, at: 0)
        }
        if transcriptItems.isEmpty {
            transcriptItems.append(CPListItem(
                text: emptyTranscriptText(session.phase),
                detailText: nil
            ))
        }
        let transcriptSection = CPListSection(
            items: transcriptItems,
            header: "transcript",
            sectionIndexTitle: nil
        )

        return [statusSection, transcriptSection]
    }

    private func activePhaseSymbol(_ phase: VoiceSessionPhase) -> String {
        switch phase {
        case .connecting: return "antenna.radiowaves.left.and.right"
        case .listening:  return "ear.fill"
        case .thinking:   return "cpu"
        case .handoff:    return "hammer.fill"
        case .speaking:   return "waveform"
        case .error:      return "exclamationmark.triangle.fill"
        }
    }

    private func emptyTranscriptText(_ phase: VoiceSessionPhase) -> String {
        switch phase {
        case .connecting: return "Connecting…"
        case .listening:  return "Listening — say something"
        case .thinking:   return "Codex is thinking"
        case .handoff:    return "Running tools"
        case .speaking:   return "Codex is speaking"
        case .error:      return "Session ended"
        }
    }

    private func pushActiveSession(_ session: VoiceSessionState) {
        configureNowPlayingTemplate(session)
        updateNowPlayingInfo(session)
        isShowingNowPlaying = true
        lastPhase = session.phase
        lastTranscriptHistoryID = session.transcriptHistory.last?.id
        lastTranscriptLive = session.transcriptText
        interfaceController?.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
    }

    private func openTranscript() {
        guard let session = voiceActions.activeVoiceSession, !isShowingTranscript else { return }
        let template = buildTranscriptTemplate(session)
        transcriptTemplate = template
        isShowingTranscript = true
        interfaceController?.pushTemplate(template, animated: true, completion: nil)
    }

    private func updateActiveSession(_ session: VoiceSessionState) {
        updateNowPlayingInfo(session)
        configureNowPlayingTemplate(session)
        if let template = transcriptTemplate, isShowingTranscript {
            template.updateSections(transcriptSections(session))
        }
    }

    private func refreshActiveSessionIfNeeded() async {
        let session = voiceActions.activeVoiceSession

        if let session {
            if !isShowingNowPlaying {
                pushActiveSession(session)
            } else {
                let historyID = session.transcriptHistory.last?.id
                if session.phase != lastPhase
                    || historyID != lastTranscriptHistoryID
                    || session.transcriptText != lastTranscriptLive {
                    updateActiveSession(session)
                    lastPhase = session.phase
                    lastTranscriptHistoryID = historyID
                    lastTranscriptLive = session.transcriptText
                }
            }
            refreshVoiceTab()
        } else if isShowingNowPlaying {
            isShowingNowPlaying = false
            isShowingTranscript = false
            transcriptTemplate = nil
            lastPhase = nil
            lastTranscriptHistoryID = nil
            lastTranscriptLive = nil
            clearNowPlayingInfo()
            _ = try? await interfaceController?.popToRootTemplate(animated: true)
            refreshVoiceTab()
        }
    }

    // MARK: - Actions

    private func handleStart() {
        Task { @MainActor in
            if voiceActions.activeVoiceSession != nil {
                openActiveSession()
                return
            }
            do {
                let cwd = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first?.path ?? "/"
                try await voiceActions.startPinnedLocalVoiceCall(
                    cwd: cwd,
                    model: nil,
                    approvalPolicy: .never,
                    sandboxMode: nil
                )
                if let session = voiceActions.activeVoiceSession {
                    pushActiveSession(session)
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func handleResume(_ key: ThreadKey) {
        Task { @MainActor in
            do {
                try await voiceActions.startVoiceOnThread(key)
                if let session = voiceActions.activeVoiceSession {
                    pushActiveSession(session)
                }
            } catch {
                showError(error.localizedDescription)
            }
        }
    }

    private func handleEnd() {
        Task { @MainActor in
            await voiceActions.stopActiveVoiceSession()
        }
    }

    private func openActiveSession() {
        guard let session = voiceActions.activeVoiceSession else { return }
        if !isShowingNowPlaying {
            pushActiveSession(session)
        }
        openTranscript()
    }

    private func openSessionsTab() {
        guard let sessionsTemplate = sessionsTabTemplate,
              let root = interfaceController?.rootTemplate as? CPTabBarTemplate,
              let idx = root.templates.firstIndex(where: { $0 === sessionsTemplate }) else { return }
        root.selectTemplate(at: idx)
    }

    private func mostRecentResumable() -> AppSessionSummary? {
        (appModel.snapshot?.sessionSummaries ?? [])
            .filter { !$0.isSubagent && $0.key.serverId == VoiceRuntimeController.localServerID }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .first
    }

    private func showError(_ message: String) {
        let action = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    // MARK: - Utilities

    private func truncate(_ s: String, max: Int) -> String {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > max ? String(trimmed.prefix(max)) + "…" : trimmed
    }

    private func relativeTime(fromEpoch epoch: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let delta = Date().timeIntervalSince(date)
        if delta < 60 { return "now" }
        if delta < 3600 { return "\(Int(delta / 60))m ago" }
        if delta < 86400 { return "\(Int(delta / 3600))h ago" }
        return "\(Int(delta / 86400))d ago"
    }
}
