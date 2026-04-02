import Observation
import SwiftUI

@MainActor
@Observable
final class AppState {
    private struct ThreadPermissionOverride {
        var approvalPolicy: String
        var sandboxMode: String
        var isUserOverride: Bool
        var rawApprovalPolicy: AppAskForApproval?
        var rawSandboxPolicy: AppSandboxPolicy?
    }

    private static let approvalPolicyKey = "litter.approvalPolicy"
    private static let sandboxModeKey = "litter.sandboxMode"
    private static let inheritPermissionValue = "inherit"
    private static let customPermissionValue = "custom"

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
    private var threadPermissionOverrides: [String: ThreadPermissionOverride] = [:]
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
        sandboxMode = UserDefaults.standard.string(forKey: Self.sandboxModeKey) ?? "danger-full-access"
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

    func approvalPolicy(for threadKey: ThreadKey?) -> String {
        guard let threadKey else { return approvalPolicy }
        return threadPermissionOverrides[permissionKey(for: threadKey)]?.approvalPolicy
            ?? Self.inheritPermissionValue
    }

    func sandboxMode(for threadKey: ThreadKey?) -> String {
        guard let threadKey else { return sandboxMode }
        return threadPermissionOverrides[permissionKey(for: threadKey)]?.sandboxMode
            ?? Self.inheritPermissionValue
    }

    func launchApprovalPolicy(for threadKey: ThreadKey?) -> AppAskForApproval? {
        guard let threadKey else {
            return AppAskForApproval(wireValue: approvalPolicy)
        }
        guard let permissions = threadPermissionOverrides[permissionKey(for: threadKey)] else {
            return nil
        }
        return permissions.rawApprovalPolicy ?? AppAskForApproval(wireValue: permissions.approvalPolicy)
    }

    func launchSandboxMode(for threadKey: ThreadKey?) -> AppSandboxMode? {
        guard let threadKey else {
            return AppSandboxMode(wireValue: sandboxMode)
        }
        guard let permissions = threadPermissionOverrides[permissionKey(for: threadKey)] else {
            return nil
        }
        return permissions.rawSandboxPolicy?.launchOverrideMode
            ?? AppSandboxMode(wireValue: permissions.sandboxMode)
    }

    func turnSandboxPolicy(for threadKey: ThreadKey?) -> AppSandboxPolicy? {
        guard let threadKey else {
            return TurnSandboxPolicy(mode: sandboxMode)?.ffiValue
        }
        guard let permissions = threadPermissionOverrides[permissionKey(for: threadKey)] else {
            return nil
        }
        return permissions.rawSandboxPolicy ?? TurnSandboxPolicy(mode: permissions.sandboxMode)?.ffiValue
    }

    func setPermissions(approvalPolicy: String, sandboxMode: String, for threadKey: ThreadKey?) {
        guard let threadKey else {
            self.approvalPolicy = approvalPolicy
            self.sandboxMode = sandboxMode
            return
        }
        threadPermissionOverrides[permissionKey(for: threadKey)] = ThreadPermissionOverride(
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            isUserOverride: true,
            rawApprovalPolicy: AppAskForApproval(wireValue: approvalPolicy),
            rawSandboxPolicy: TurnSandboxPolicy(mode: sandboxMode)?.ffiValue
        )
    }

    func hydratePermissions(from thread: AppThreadSnapshot?) {
        guard let thread else { return }
        let key = permissionKey(for: thread.key)
        if threadPermissionOverrides[key]?.isUserOverride == true { return }

        let rawApprovalPolicy = thread.effectiveApprovalPolicy
        let rawSandboxPolicy = thread.effectiveSandboxPolicy
        let approvalPolicy = displayValue(for: rawApprovalPolicy)
        let sandboxMode = displayValue(for: rawSandboxPolicy)

        if rawApprovalPolicy == nil && rawSandboxPolicy == nil {
            threadPermissionOverrides.removeValue(forKey: key)
            return
        }

        threadPermissionOverrides[key] = ThreadPermissionOverride(
            approvalPolicy: approvalPolicy,
            sandboxMode: sandboxMode,
            isUserOverride: false,
            rawApprovalPolicy: rawApprovalPolicy,
            rawSandboxPolicy: rawSandboxPolicy
        )
    }

    private func permissionKey(for threadKey: ThreadKey) -> String {
        "\(threadKey.serverId)/\(threadKey.threadId)"
    }

    private func displayValue(for approvalPolicy: AppAskForApproval?) -> String {
        guard let approvalPolicy else { return Self.inheritPermissionValue }
        return approvalPolicy.launchOverrideWireValue ?? Self.customPermissionValue
    }

    private func displayValue(for sandboxPolicy: AppSandboxPolicy?) -> String {
        guard let sandboxPolicy else { return Self.inheritPermissionValue }
        return sandboxPolicy.launchOverrideModeWireValue ?? Self.customPermissionValue
    }
}
