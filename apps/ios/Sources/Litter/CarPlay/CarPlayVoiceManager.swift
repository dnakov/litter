import CarPlay
import UIKit

@MainActor
final class CarPlayVoiceManager {
    private let voiceActions: VoiceActions
    private let appModel: AppModel
    private weak var interfaceController: CPInterfaceController?
    private var observationTask: Task<Void, Error>?
    private var isShowingActiveSession = false

    init(voiceActions: VoiceActions, appModel: AppModel, interfaceController: CPInterfaceController) {
        self.voiceActions = voiceActions
        self.appModel = appModel
        self.interfaceController = interfaceController
    }

    // MARK: - Tab Templates

    func buildVoiceTab() -> CPListTemplate {
        let template = CPListTemplate(
            title: "Voice",
            sections: [buildVoiceSection()]
        )
        template.tabImage = UIImage(systemName: "waveform")
        return template
    }

    func buildSessionsTab() -> CPListTemplate {
        var items: [CPListItem] = []

        let sorted = appModel.snapshot?.sessionSummaries
            .filter { !$0.isSubagent }
            .sorted { ($0.updatedAt ?? 0) > ($1.updatedAt ?? 0) }
            .prefix(8)
            ?? []

        for summary in sorted {
            let title = summary.preview.isEmpty
                ? "Session"
                : String(summary.preview.prefix(60))
            let detail = summary.key.serverId == VoiceRuntimeController.localServerID
                ? "local" : summary.serverDisplayName
            let item = CPListItem(text: title, detailText: detail)
            item.handler = { [weak self] _, completion in
                self?.handleResume(summary.key)
                completion()
            }
            items.append(item)
        }

        if items.isEmpty {
            let empty = CPListItem(
                text: "No recent sessions",
                detailText: "Start a voice session from the Voice tab"
            )
            items.append(empty)
        }

        let template = CPListTemplate(
            title: "Sessions",
            sections: [CPListSection(items: items)]
        )
        template.tabImage = UIImage(systemName: "list.bullet")
        return template
    }

    // MARK: - Observation

    func startObserving() {
        observationTask = Task { [weak self] in
            var lastPhase: VoiceSessionPhase?
            var lastTranscript: String?

            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { break }

                let session = self.voiceActions.activeVoiceSession

                if let session {
                    if !self.isShowingActiveSession {
                        self.pushActiveSession(session)
                    } else if session.phase != lastPhase
                                || session.transcriptText != lastTranscript {
                        self.refreshActiveSession(session)
                    }
                    lastPhase = session.phase
                    lastTranscript = session.transcriptText
                } else if self.isShowingActiveSession {
                    lastPhase = nil
                    lastTranscript = nil
                    self.isShowingActiveSession = false
                    try await self.interfaceController?.popToRootTemplate(animated: true)
                }
            }
        }
    }

    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
    }

    // MARK: - Actions

    private func handleStart() {
        Task { @MainActor in
            if voiceActions.activeVoiceSession != nil {
                if let session = voiceActions.activeVoiceSession {
                    pushActiveSession(session)
                }
                return
            }
            do {
                let cwd = FileManager.default.urls(
                    for: .documentDirectory, in: .userDomainMask
                ).first?.path ?? "/"
                try await voiceActions.startPinnedLocalVoiceCall(
                    cwd: cwd,
                    model: nil,
                    approvalPolicy: "never",
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

    // MARK: - Template Building

    private func buildVoiceSection() -> CPListSection {
        let startItem = CPListItem(
            text: "Start Voice Session",
            detailText: "On-device Codex",
            image: UIImage(systemName: "mic.fill")
        )
        startItem.handler = { [weak self] _, completion in
            self?.handleStart()
            completion()
        }
        return CPListSection(items: [startItem])
    }

    private func buildInfoTemplate(_ session: VoiceSessionState) -> CPInformationTemplate {
        let items = [
            CPInformationItem(title: "Status", detail: session.phase.displayTitle),
            CPInformationItem(title: "Route", detail: session.route.label),
            CPInformationItem(
                title: "Transcript",
                detail: session.truncatedTranscript() ?? "—"
            )
        ]
        let endButton = CPTextButton(
            title: "End Session",
            textStyle: .cancel
        ) { [weak self] _ in
            Task { await self?.voiceActions.stopActiveVoiceSession() }
        }
        return CPInformationTemplate(
            title: session.model,
            layout: .leading,
            items: items,
            actions: [endButton]
        )
    }

    private func pushActiveSession(_ session: VoiceSessionState) {
        let template = buildInfoTemplate(session)
        isShowingActiveSession = true
        interfaceController?.pushTemplate(template, animated: true)
    }

    private func refreshActiveSession(_ session: VoiceSessionState) {
        let template = buildInfoTemplate(session)
        // CPInformationTemplate items aren't mutable, so pop and push
        interfaceController?.popTemplate(animated: false)
        interfaceController?.pushTemplate(template, animated: false)
    }

    private func showError(_ message: String) {
        let action = CPAlertAction(title: "OK", style: .cancel) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: [message],
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true)
    }
}
