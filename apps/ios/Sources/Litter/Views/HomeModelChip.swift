import SwiftUI

/// Small tap-to-open model picker for the home composer bar, styled to
/// match `ProjectChip` so the two sit together above the input. Reads +
/// writes the persisted home defaults (`appState.preferredModel` /
/// `appState.preferredReasoningEffort`) so the choice survives thread
/// switches and app relaunches before the next `startThread` call.
struct HomeModelChip: View {
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false

    /// The server the chip should pull available models from. Typically
    /// the currently-selected project's serverId; when nothing is picked
    /// the chip is disabled.
    let serverId: String?
    let disabled: Bool

    @State private var showSheet = false
    @State private var selectedDetent: PresentationDetent = .large

    /// Whether the user has escalated the pre-thread launch permissions to
    /// the equivalent of the header's "Full Access" preset.
    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: nil)
        let sandbox = appState.turnSandboxPolicy(for: nil)
        return threadPermissionPreset(
            approvalPolicy: approval,
            sandboxPolicy: sandbox
        ) == .fullAccess
    }

    private var isPlanMode: Bool {
        appState.pendingCollaborationMode == .plan
    }

    private var availableModels: [ModelInfo] {
        guard let serverId else { return [] }
        return appModel.availableModels(for: serverId)
    }

    private var selectedModelLabel: String {
        let trimmed = appState.preferredModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            if let match = availableModels.first(where: { $0.id == trimmed }) {
                return match.displayName
            }
            return trimmed
        }
        if let defaultModel = availableModels.first(where: { $0.isDefault }) {
            return defaultModel.displayName
        }
        return "model"
    }

    private var reasoningLabel: String {
        let trimmed = appState.preferredReasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ""
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: { appState.preferredModel },
            set: { appState.preferredModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: { appState.preferredReasoningEffort },
            set: { appState.preferredReasoningEffort = $0 }
        )
    }

    var body: some View {
        Button {
            selectedDetent = .large
            showSheet = true
        } label: {
            HStack(spacing: 6) {
                if fastMode {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LitterTheme.warning)
                }
                Image(systemName: "cpu")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(disabled ? LitterTheme.textMuted : LitterTheme.accent)
                Text(selectedModelLabel)
                    .litterMonoFont(size: 12, weight: .semibold)
                    .foregroundStyle(disabled ? LitterTheme.textSecondary : LitterTheme.textPrimary)
                    .lineLimit(1)
                if !reasoningLabel.isEmpty {
                    Text(reasoningLabel)
                        .litterMonoFont(size: 11, weight: .regular)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.85))
                        .lineLimit(1)
                }
                if isPlanMode {
                    Text("plan")
                        .litterMonoFont(size: 10, weight: .bold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(LitterTheme.accent, in: Capsule())
                }
                if isFullAccess {
                    Image(systemName: "lock.open.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LitterTheme.danger)
                }
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(LitterTheme.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
        .overlay(
            Capsule(style: .continuous)
                .stroke(LitterTheme.textMuted.opacity(0.55), lineWidth: 0.8)
                .allowsHitTesting(false)
        )
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .sheet(isPresented: $showSheet) {
            ConversationOptionsSheet(
                models: availableModels,
                selectedModel: selectedModelBinding,
                reasoningEffort: reasoningEffortBinding,
                threadKey: nil
            )
            .environment(appModel)
            .environment(appState)
            .presentationDetents([.medium, .large], selection: $selectedDetent)
            .presentationDragIndicator(.visible)
            .presentationContentInteraction(.scrolls)
            .presentationBackground(LitterTheme.surface)
        }
        .task(id: serverId) {
            guard let serverId else { return }
            await appModel.loadConversationMetadataIfNeeded(serverId: serverId)
        }
    }
}
