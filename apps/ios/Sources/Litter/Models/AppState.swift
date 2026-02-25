import SwiftUI

@MainActor
final class AppState: ObservableObject {
    private static let approvalPolicyKey = "composer_approval_policy"
    private static let sandboxModeKey = "composer_sandbox_mode"

    @Published var sidebarOpen = false
    @Published var currentCwd = ""
    @Published var showServerPicker = false
    @Published var collapsedSessionFolders: Set<String> = []
    @Published var selectedModel = ""
    @Published var reasoningEffort = "medium"
    @Published var approvalPolicy: String {
        didSet {
            UserDefaults.standard.set(approvalPolicy, forKey: Self.approvalPolicyKey)
        }
    }
    @Published var sandboxMode: String {
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
