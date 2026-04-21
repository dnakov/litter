import Foundation
import WatchConnectivity
import WidgetKit

/// Watch-side WatchConnectivity bridge. Receives snapshots from the iOS
/// app via `updateApplicationContext` and forwards user actions back via
/// `sendMessage` (approval decisions, voice prompts).
@MainActor
final class WatchSessionBridge: NSObject, WCSessionDelegate {
    static let shared = WatchSessionBridge()

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Outbound

    func sendApprovalDecision(requestId: String, approve: Bool) {
        sendMessage([
            "kind": "approval.decision",
            "requestId": requestId,
            "approve": approve
        ])
    }

    /// Send a dictated prompt to the phone. Phone-side decides which thread
    /// the prompt lands on.
    func sendPrompt(_ text: String, serverId: String? = nil) {
        var payload: [String: Any] = [
            "kind": "prompt.send",
            "text": text
        ]
        if let serverId { payload["serverId"] = serverId }
        sendMessage(payload)
    }

    /// Trigger a fresh snapshot push from the phone.
    func requestSnapshot() {
        sendMessage(["kind": "snapshot.request"])
    }

    private func sendMessage(_ payload: [String: Any]) {
        guard WCSession.default.activationState == .activated else { return }
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(payload, replyHandler: nil) { _ in }
        } else {
            // Fallback: queue via transferUserInfo so the phone receives it
            // when it wakes up.
            WCSession.default.transferUserInfo(payload)
        }
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            WatchAppStore.shared.isReachable = session.isReachable
            if state == .activated {
                self.requestSnapshot()
            }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            WatchAppStore.shared.isReachable = session.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handle(applicationContext)
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        handle(userInfo)
    }

    private nonisolated func handle(_ payload: [String: Any]) {
        guard
            let raw = payload["litter.snapshot"] as? Data,
            let snapshot = try? JSONDecoder().decode(WatchSnapshotPayload.self, from: raw)
        else { return }

        Task { @MainActor in
            let store = WatchAppStore.shared
            store.tasks = snapshot.tasks
            store.pendingApproval = snapshot.pendingApproval
            // Keep local focus if it's still valid, otherwise pick first task.
            if let id = store.focusedTaskId,
               !snapshot.tasks.contains(where: { $0.id == id }) {
                store.focusedTaskId = snapshot.tasks.first?.id
            } else if store.focusedTaskId == nil {
                store.focusedTaskId = snapshot.tasks.first?.id
            }
            store.lastSyncDate = .now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

