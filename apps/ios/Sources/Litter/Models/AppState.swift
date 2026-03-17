import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    private static let approvalPolicyKey = "litter.approvalPolicy"
    private static let sandboxModeKey = "litter.sandboxMode"

    var currentCwd = ""
    var showServerPicker = false
    var collapsedSessionFolders: Set<String> = []
    var sessionsSelectedServerFilterId: String?
    var sessionsShowOnlyForks = false
    var sessionsWorkspaceSortModeRaw = "mostRecent"
    var selectedModel = ""
    var reasoningEffort = ""
    var showModelSelector = false
    var showSettings = false
    var pendingThreadNavigation: ThreadKey?
    var approvalPolicy: String {
        didSet {
            UserDefaults.standard.set(approvalPolicy, forKey: Self.approvalPolicyKey)
        }
    }
    var sandboxMode: String {
        didSet {
            UserDefaults.standard.set(sandboxMode, forKey: Self.sandboxModeKey)
        }
    }

    init() {
        approvalPolicy = UserDefaults.standard.string(forKey: Self.approvalPolicyKey) ?? "never"
        sandboxMode = UserDefaults.standard.string(forKey: Self.sandboxModeKey) ?? "workspace-write"
    }

    func toggleSessionFolder(_ folderPath: String) {
        if collapsedSessionFolders.contains(folderPath) {
            collapsedSessionFolders.remove(folderPath)
        } else {
            collapsedSessionFolders.insert(folderPath)
        }
    }

    func isSessionFolderCollapsed(_ folderPath: String) -> Bool {
        collapsedSessionFolders.contains(folderPath)
    }
}
