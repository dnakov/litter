import ActivityKit
import Foundation

@MainActor
final class TurnLiveActivityController {
    private var liveActivities: [ThreadKey: Activity<CodexTurnAttributes>] = [:]
    private var liveActivityStartDates: [ThreadKey: Date] = [:]
    private var liveActivityOutputSnippets: [ThreadKey: String] = [:]
    private var liveActivityLastUpdateTimes: [ThreadKey: CFAbsoluteTime] = [:]

    func sync(_ snapshot: AppSnapshotRecord?) {
        guard let snapshot else {
            endAll(phase: .completed, snapshot: nil)
            return
        }

        let activeThreads = snapshot.threads.filter(\.hasActiveTurn)
        let activeKeys = Set(activeThreads.map(\.key))

        startIfNeeded(for: activeThreads)
        for thread in activeThreads {
            update(for: thread)
        }

        for key in Array(liveActivities.keys) where !activeKeys.contains(key) {
            end(key: key, phase: .completed, snapshot: snapshot)
        }
    }

    func startIfNeeded(for threads: [AppThreadSnapshot]) {
        for thread in threads {
            let key = thread.key
            guard liveActivities[key] == nil, ActivityAuthorizationInfo().areActivitiesEnabled else {
                continue
            }

            let now = Date()
            let attributes = CodexTurnAttributes(
                threadId: key.threadId,
                model: thread.resolvedModel,
                cwd: thread.info.cwd ?? "",
                startDate: now,
                prompt: String(thread.resolvedPreview.prefix(120))
            )
            let state = CodexTurnAttributes.ContentState(
                phase: .thinking,
                elapsedSeconds: 0,
                toolCallCount: 0,
                activeThreadCount: max(1, threads.count),
                fileChangeCount: 0,
                contextPercent: thread.contextPercent
            )
            liveActivityStartDates[key] = now
            do {
                liveActivities[key] = try Activity.request(
                    attributes: attributes,
                    content: .init(state: state, staleDate: nil)
                )
            } catch {}
        }
    }

    func update(for thread: AppThreadSnapshot) {
        let key = thread.key
        guard let activity = liveActivities[key] else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let sinceLastUpdate = now - (liveActivityLastUpdateTimes[key] ?? 0)
        guard sinceLastUpdate > 2.0 else { return }

        if let snippet = thread.latestAssistantSnippet, !snippet.isEmpty {
            liveActivityOutputSnippets[key] = snippet
        }

        let state = CodexTurnAttributes.ContentState(
            phase: .thinking,
            elapsedSeconds: Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date())),
            toolCallCount: 0,
            activeThreadCount: liveActivities.count,
            outputSnippet: liveActivityOutputSnippets[key],
            fileChangeCount: 0,
            contextPercent: thread.contextPercent
        )
        liveActivityLastUpdateTimes[key] = now
        Task {
            await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60)))
        }
    }

    func updateBackgroundWake(for thread: AppThreadSnapshot, pushCount: Int) {
        let key = thread.key
        guard let activity = liveActivities[key] else { return }
        if let snippet = thread.latestAssistantSnippet, !snippet.isEmpty {
            liveActivityOutputSnippets[key] = snippet
        }

        let state = CodexTurnAttributes.ContentState(
            phase: .thinking,
            elapsedSeconds: Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date())),
            toolCallCount: 0,
            activeThreadCount: liveActivities.count,
            outputSnippet: liveActivityOutputSnippets[key],
            pushCount: pushCount,
            fileChangeCount: 0,
            contextPercent: thread.contextPercent
        )
        liveActivityLastUpdateTimes[key] = CFAbsoluteTimeGetCurrent()
        Task {
            await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60)))
        }
    }

    func end(key: ThreadKey, phase: CodexTurnAttributes.ContentState.Phase, snapshot: AppSnapshotRecord?) {
        guard let activity = liveActivities[key] else { return }
        let thread = snapshot?.threadSnapshot(for: key)
        let state = CodexTurnAttributes.ContentState(
            phase: phase,
            elapsedSeconds: Int(Date().timeIntervalSince(liveActivityStartDates[key] ?? Date())),
            toolCallCount: 0,
            activeThreadCount: max(0, liveActivities.count - 1),
            outputSnippet: liveActivityOutputSnippets[key],
            fileChangeCount: 0,
            contextPercent: thread?.contextPercent ?? 0
        )
        let content = ActivityContent(state: state, staleDate: Date(timeIntervalSinceNow: 60))
        Task {
            await activity.end(content, dismissalPolicy: .after(.now + 4))
        }
        liveActivities.removeValue(forKey: key)
        liveActivityStartDates.removeValue(forKey: key)
        liveActivityOutputSnippets.removeValue(forKey: key)
        liveActivityLastUpdateTimes.removeValue(forKey: key)
    }

    private func endAll(phase: CodexTurnAttributes.ContentState.Phase, snapshot: AppSnapshotRecord?) {
        for key in Array(liveActivities.keys) {
            end(key: key, phase: phase, snapshot: snapshot)
        }
    }
}
