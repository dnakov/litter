import Foundation
import Combine
import WatchConnectivity
#if canImport(WidgetKit)
import WidgetKit
#endif

/// iOS side of the Watch companion pipeline.
///
/// - Observes `AppModel.shared.snapshot` and whenever it changes, projects
///   the relevant slice into a `WatchSnapshotPayload` and pushes it to the
///   paired watch via `WCSession.updateApplicationContext`.
/// - Writes a lightweight complication snapshot to the shared App Group so
///   the watchOS complications can read it even when the app isn't active.
/// - Receives inbound messages from the watch (approval decisions,
///   dictated prompts) and dispatches them back into `AppStore` / composer.
///
/// Kept thin: no state reducer logic here. Just projection + plumbing.
@MainActor
final class WatchCompanionBridge: NSObject {
    static let shared = WatchCompanionBridge()

    private let delegate = WatchCompanionSessionDelegate()
    private var lastPushedPayload: WatchSnapshotPayload?
    private var lastPushedComplication: Data?
    private var observationTask: Task<Void, Never>?
    private var pushThrottle: Task<Void, Never>?

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = delegate
        session.activate()
        beginObservingAppModel()
    }

    // MARK: - Observation

    private func beginObservingAppModel() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // Poll the Observable `AppModel.shared` via a coalesced
                // 250ms tick; Observation tracking inside a bare `withObservationTracking`
                // would fire on every transient mutation, which is too noisy for a
                // cross-device channel.
                self?.pushIfChanged()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private func pushIfChanged() {
        let payload = currentPayload()
        let complication = currentComplicationSnapshot()

        if payload != lastPushedPayload {
            lastPushedPayload = payload
            push(payload: payload)
        }

        if complication != lastPushedComplication {
            lastPushedComplication = complication
            writeComplication(complication)
        }
    }

    // MARK: - Projection

    private func currentPayload() -> WatchSnapshotPayload {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []

        let tasks = WatchProjection.tasks(
            summaries: summaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )

        return WatchSnapshotPayload(
            tasks: tasks,
            pendingApproval: pendingApprovals
                .first(where: { $0.kind != .mcpElicitation })
                .map(WatchProjection.approval)
        )
    }

    private func currentComplicationSnapshot() -> Data? {
        let snapshot = AppModel.shared.snapshot
        let summaries = snapshot?.sessionSummaries ?? []
        let threads = snapshot?.threads ?? []
        let pendingApprovals = snapshot?.pendingApprovals ?? []
        let connectedCount = (snapshot?.servers ?? [])
            .filter { $0.transportState == .connected }.count

        let tasks = WatchProjection.tasks(
            summaries: summaries,
            threads: threads,
            pendingApprovals: pendingApprovals
        )
        let runningTask = tasks.first { $0.status == .running }
            ?? tasks.first { $0.status == .needsApproval }

        let mode: String
        let title: String
        let toolLine: String
        let progress: Double
        let runtime: Int

        if let task = runningTask {
            mode = task.status == .needsApproval ? "running" : "running"
            title = task.title
            toolLine = task.subtitle ?? "working"
            let total = max(task.steps.count, 1)
            let done = task.steps.filter({ $0.state == .done }).count
            progress = total > 0 ? Double(done) / Double(total) : 0.5
            runtime = 0
        } else if tasks.isEmpty {
            mode = "idle"
            title = "\(connectedCount) servers ready"
            toolLine = "tap to open"
            progress = 1
            runtime = 0
        } else {
            mode = "idle"
            title = "\(tasks.count) task\(tasks.count == 1 ? "" : "s")"
            toolLine = tasks.first?.title ?? ""
            progress = 1
            runtime = 0
        }

        let dict: [String: Any] = [
            "mode": mode,
            "runtimeSeconds": runtime,
            "progress": progress,
            "title": title,
            "toolLine": toolLine,
            "serverCount": connectedCount
        ]

        return try? JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Outbound

    private func push(payload: WatchSnapshotPayload) {
        guard WCSession.default.activationState == .activated else { return }
        guard WCSession.default.isPaired && WCSession.default.isWatchAppInstalled else { return }
        guard let data = try? JSONEncoder().encode(payload) else { return }

        // Throttle: coalesce rapid mutations into a single updateApplicationContext.
        pushThrottle?.cancel()
        pushThrottle = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled else { return }
            do {
                try WCSession.default.updateApplicationContext(["litter.snapshot": data])
            } catch {
                LLog.error("watch", "push failed: \(error.localizedDescription)")
            }
            // Also send via message if reachable for instant delivery.
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(
                    ["litter.snapshot": data],
                    replyHandler: nil,
                    errorHandler: nil
                )
            }
        }
    }

    private func writeComplication(_ data: Data?) {
        guard let data,
              let defaults = UserDefaults(suiteName: "group.com.sigkitten.litter")
        else { return }
        defaults.set(data, forKey: "complication.snapshot.v1")

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    // MARK: - Inbound

    /// Called by the `WCSessionDelegate` proxy on the main actor.
    func handleInbound(_ message: [String: Any]) {
        guard let kind = message["kind"] as? String else {
            // Unkeyed — could be a raw snapshot echo; ignore.
            return
        }
        switch kind {
        case "approval.decision":
            guard
                let requestId = message["requestId"] as? String,
                let approve = message["approve"] as? Bool
            else { return }
            Task {
                try? await AppModel.shared.store.respondToApproval(
                    requestId: requestId,
                    decision: approve ? .accept : .decline
                )
            }

        case "prompt.send":
            guard let text = message["text"] as? String, !text.isEmpty else { return }
            if let key = AppModel.shared.snapshot?.activeThread {
                AppModel.shared.queueComposerPrefill(threadKey: key, text: text)
            }

        case "snapshot.request":
            lastPushedPayload = nil
            lastPushedComplication = nil
            pushIfChanged()

        default:
            break
        }
    }
}

/// WCSessionDelegate proxy. Declared as a separate class so the bridge can
/// own a single activation + delegate lifecycle.
final class WatchCompanionSessionDelegate: NSObject, WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            // On activation, re-push so the watch gets current state.
            WatchCompanionBridge.shared.handleInbound(["kind": "snapshot.request"])
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchCompanionBridge.shared.handleInbound(["kind": "snapshot.request"])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in
            WatchCompanionBridge.shared.handleInbound(message)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor in
            WatchCompanionBridge.shared.handleInbound(message)
            replyHandler(["ok": true])
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in
            WatchCompanionBridge.shared.handleInbound(userInfo)
        }
    }
}
