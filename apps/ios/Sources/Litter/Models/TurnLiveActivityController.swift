import ActivityKit
import Foundation

@MainActor
final class TurnLiveActivityController {
    private var activity: Activity<CodexTurnAttributes>?
    private var activeKey: ThreadKey?
    private var startDate: Date?
    private var outputSnippet: String?
    private var lastUpdateTime: CFAbsoluteTime = 0
    private var didCleanupStaleActivities = false

    private func cleanupStaleActivities() {
        guard !didCleanupStaleActivities else { return }
        didCleanupStaleActivities = true
        for stale in Activity<CodexTurnAttributes>.activities {
            let state = CodexTurnAttributes.ContentState(
                phase: .completed, elapsedSeconds: 0, toolCallCount: 0,
                activeThreadCount: 0, fileChangeCount: 0, contextPercent: 0
            )
            Task {
                await stale.end(.init(state: state, staleDate: nil), dismissalPolicy: .immediate)
            }
        }
    }

    func sync(_ snapshot: AppSnapshotRecord?) {
        cleanupStaleActivities()

        guard let snapshot else {
            endCurrent(phase: .completed, snapshot: nil)
            return
        }

        let activeThreads = snapshot.threads.filter(\.hasActiveTurn)

        if activeThreads.isEmpty {
            endCurrent(phase: .completed, snapshot: snapshot)
            return
        }

        // Pick the best thread to show: prefer the active thread, else most recent.
        let best = activeThreads.first(where: { $0.key == snapshot.activeThread })
            ?? activeThreads.first!

        if let currentKey = activeKey, currentKey != best.key {
            // Active thread changed — end old, start new.
            endCurrent(phase: .completed, snapshot: snapshot)
        }

        if activity == nil {
            start(for: best, activeCount: activeThreads.count)
        } else {
            update(for: best, activeCount: activeThreads.count)
        }
    }

    private func start(for thread: AppThreadSnapshot, activeCount: Int) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let now = Date()
        let attributes = CodexTurnAttributes(
            threadId: thread.key.threadId,
            model: thread.resolvedModel,
            cwd: thread.info.cwd ?? "",
            startDate: now,
            prompt: String(thread.resolvedPreview.prefix(120))
        )
        let state = CodexTurnAttributes.ContentState(
            phase: .thinking,
            elapsedSeconds: 0,
            toolCallCount: 0,
            activeThreadCount: max(1, activeCount),
            fileChangeCount: 0,
            contextPercent: thread.contextPercent
        )
        activeKey = thread.key
        startDate = now
        outputSnippet = nil
        lastUpdateTime = 0
        do {
            activity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil)
            )
        } catch {}
    }

    private func update(for thread: AppThreadSnapshot, activeCount: Int) {
        guard let activity else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastUpdateTime > 2.0 else { return }

        if let snippet = thread.latestAssistantSnippet, !snippet.isEmpty {
            outputSnippet = snippet
        }

        let state = CodexTurnAttributes.ContentState(
            phase: .thinking,
            elapsedSeconds: Int(Date().timeIntervalSince(startDate ?? Date())),
            toolCallCount: 0,
            activeThreadCount: max(1, activeCount),
            outputSnippet: outputSnippet,
            fileChangeCount: 0,
            contextPercent: thread.contextPercent
        )
        lastUpdateTime = now
        Task {
            await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60)))
        }
    }

    func updateBackgroundWake(for thread: AppThreadSnapshot, pushCount: Int) {
        guard let activity else { return }
        if let snippet = thread.latestAssistantSnippet, !snippet.isEmpty {
            outputSnippet = snippet
        }

        let state = CodexTurnAttributes.ContentState(
            phase: .thinking,
            elapsedSeconds: Int(Date().timeIntervalSince(startDate ?? Date())),
            toolCallCount: 0,
            activeThreadCount: 1,
            outputSnippet: outputSnippet,
            pushCount: pushCount,
            fileChangeCount: 0,
            contextPercent: thread.contextPercent
        )
        lastUpdateTime = CFAbsoluteTimeGetCurrent()
        Task {
            await activity.update(.init(state: state, staleDate: Date(timeIntervalSinceNow: 60)))
        }
    }

    func endCurrent(phase: CodexTurnAttributes.ContentState.Phase, snapshot: AppSnapshotRecord?) {
        guard let activity else { return }
        let thread = activeKey.flatMap { snapshot?.threadSnapshot(for: $0) }
        let state = CodexTurnAttributes.ContentState(
            phase: phase,
            elapsedSeconds: Int(Date().timeIntervalSince(startDate ?? Date())),
            toolCallCount: 0,
            activeThreadCount: 0,
            outputSnippet: outputSnippet,
            fileChangeCount: 0,
            contextPercent: thread?.contextPercent ?? 0
        )
        Task {
            await activity.end(
                .init(state: state, staleDate: Date(timeIntervalSinceNow: 60)),
                dismissalPolicy: .after(.now + 4)
            )
        }
        self.activity = nil
        activeKey = nil
        startDate = nil
        outputSnippet = nil
        lastUpdateTime = 0
    }
}
