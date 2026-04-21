import Foundation
import Combine
import WatchConnectivity

/// Observable state container for the watch app. Sourced from the iPhone
/// via `WatchSessionBridge`; starts empty and populates on first snapshot.
@MainActor
final class WatchAppStore: ObservableObject {
    @Published var tasks: [WatchTask] = []
    /// The task the user is currently drilled into. Purely local — the
    /// transcript for each task is carried inside the task itself, so this
    /// doesn't need to round-trip to the phone.
    @Published var focusedTaskId: String?
    @Published var pendingApproval: WatchApproval?
    @Published var isReachable: Bool = false
    @Published var lastSyncDate: Date?

    static let shared = WatchAppStore()

    var focusedTask: WatchTask? {
        if let id = focusedTaskId, let task = tasks.first(where: { $0.id == id }) {
            return task
        }
        return tasks.first
    }

    var runningTaskCount: Int {
        tasks.filter { $0.status == .running }.count
    }

    var approvalsTaskCount: Int {
        tasks.filter { $0.status == .needsApproval }.count
    }

    var hasData: Bool {
        lastSyncDate != nil
    }

    // MARK: - Outbound (watch → phone)

    func respond(approve: Bool) {
        guard let approval = pendingApproval else { return }
        pendingApproval = nil
        WatchSessionBridge.shared.sendApprovalDecision(
            requestId: approval.id,
            approve: approve
        )
    }

    /// Remember which task the user drilled into — local only.
    func focus(on task: WatchTask) {
        focusedTaskId = task.id
    }

    #if DEBUG
    static func previewStore() -> WatchAppStore {
        let store = WatchAppStore()
        store.tasks = WatchPreviewFixtures.tasks
        store.focusedTaskId = WatchPreviewFixtures.tasks.first?.id
        store.pendingApproval = WatchPreviewFixtures.approval
        store.lastSyncDate = .now
        store.isReachable = true
        return store
    }
    #endif
}
