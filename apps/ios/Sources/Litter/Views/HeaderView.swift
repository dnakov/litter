import SafariServices
import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    @State private var pulsing = false
    @AppStorage("fastMode") private var fastMode = false

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    private var headerPermissionPreset: AppThreadPermissionPreset {
        let approval = appState.launchApprovalPolicy(for: thread.key) ?? thread.effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: thread.key) ?? thread.effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox)
    }

    var body: some View {
        Button {
            appState.showModelSelector.toggle()
        } label: {
            VStack(spacing: 2) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusDotColor)
                        .frame(width: 6, height: 6)
                        .opacity(shouldPulse ? (pulsing ? 0.3 : 1.0) : 1.0)
                        .animation(shouldPulse ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true) : .default, value: pulsing)
                        .onChange(of: shouldPulse) { _, pulse in
                            pulsing = pulse
                        }
                    if fastMode {
                        Image(systemName: "bolt.fill")
                            .font(LitterFont.styled(size: 10, weight: .semibold))
                            .foregroundColor(LitterTheme.warning)
                    }
                    Text(sessionModelLabel)
                        .foregroundColor(LitterTheme.textPrimary)
                    Text(sessionReasoningLabel)
                        .foregroundColor(LitterTheme.textSecondary)
                    Image(systemName: "chevron.down")
                        .font(LitterFont.styled(size: 10, weight: .semibold))
                        .foregroundColor(LitterTheme.textSecondary)
                        .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
                }
                .font(LitterFont.styled(size: 14, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)

                HStack(spacing: 6) {
                    Text(sessionDirectoryLabel)
                        .font(LitterFont.styled(size: 11, weight: .semibold))
                        .foregroundColor(LitterTheme.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if thread.collaborationMode == .plan {
                        Text("plan")
                            .font(LitterFont.styled(size: 11, weight: .bold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LitterTheme.accent)
                            .clipShape(Capsule())
                    }

                    if headerPermissionPreset == .fullAccess {
                        Image(systemName: "lock.open.fill")
                            .font(LitterFont.styled(size: 10, weight: .semibold))
                            .foregroundColor(LitterTheme.danger)
                    }

                    if server?.isIpcConnected == true, ExperimentalFeatures.shared.isEnabled(.ipc) {
                        Text("IPC")
                            .font(LitterFont.styled(size: 11, weight: .bold))
                            .foregroundColor(LitterTheme.accentStrong)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LitterTheme.accentStrong.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: 240)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("header.modelPickerButton")
        .popover(
            isPresented: Binding(
                get: { appState.showModelSelector },
                set: { appState.showModelSelector = $0 }
            ),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .top
        ) {
            ConversationModelPickerPanel(thread: thread)
                .presentationCompactAdaptation(.popover)
        }
        .task(id: thread.key) {
            await loadModelsIfNeeded()
        }
    }

    private var shouldPulse: Bool {
        guard let transportState = server?.transportState else { return false }
        return transportState == .connecting || transportState == .unresponsive
    }

    private var statusDotColor: Color {
        guard let server else {
            return LitterTheme.textMuted
        }
        switch server.transportState {
        case .connecting, .unresponsive:
            return .orange
        case .connected:
            if server.hasIpc && server.ipcState == .disconnected && ExperimentalFeatures.shared.isEnabled(.ipc) {
                return .orange
            }
            if server.isLocal {
                switch server.account {
                case .chatgpt?, .apiKey?:
                    return LitterTheme.success
                case nil:
                    return LitterTheme.danger
                }
            }
            return server.account == nil ? .orange : LitterTheme.success
        case .disconnected:
            return LitterTheme.danger
        case .unknown:
            return LitterTheme.textMuted
        }
    }

    private var sessionModelLabel: String {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingModel.isEmpty { return pendingModel }

        let threadModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty { return threadModel }

        return "litter"
    }

    private var sessionReasoningLabel: String {
        let pendingReasoning = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingReasoning.isEmpty { return pendingReasoning }

        let threadReasoning = thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty { return threadReasoning }

        // Fall back to the model's default reasoning effort from the loaded model list.
        let currentModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if let model = availableModels.first(where: { $0.model == currentModel }),
           !model.defaultReasoningEffort.wireValue.isEmpty {
            return model.defaultReasoningEffort.wireValue
        }

        return "default"
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = (thread.info.cwd ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !currentDirectory.isEmpty {
            return abbreviateHomePath(currentDirectory)
        }

        return "~"
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }

    private func loadModelsIfNeeded() async {
        await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
    }
}

struct ConversationModelPickerPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    var body: some View {
        InlineModelSelectorView(
            models: availableModels,
            selectedModel: selectedModelBinding,
            reasoningEffort: reasoningEffortBinding,
            threadKey: thread.key,
            collaborationMode: thread.collaborationMode,
            effectiveApprovalPolicy: thread.effectiveApprovalPolicy,
            effectiveSandboxPolicy: thread.effectiveSandboxPolicy,
            onDismiss: {
                appState.showModelSelector = false
            }
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .task(id: thread.key) {
            await appModel.loadConversationMetadataIfNeeded(serverId: thread.key.serverId)
        }
    }

    private var selectedModelBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.selectedModel = $0 }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.reasoningEffort = $0 }
        )
    }
}

struct ConversationToolbarControls: View {
    enum Control {
        case reload
        case info
    }

    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    let control: Control
    var onInfo: (() -> Void)?
    @State private var isReloading = false
    @State private var remoteAuthSession: RemoteAuthSession?

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    var body: some View {
        Group {
            switch control {
            case .reload:
                reloadButton
            case .info:
                infoButton
            }
        }
        .frame(width: 28, height: 28)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .sheet(item: $remoteAuthSession) { session in
            InAppSafariView(url: session.url)
                .ignoresSafeArea()
        }
        .onChange(of: server?.account != nil) { _, isLoggedIn in
            if isLoggedIn {
                remoteAuthSession = nil
            }
        }
    }

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                defer { isReloading = false }
                if await handleRemoteLoginIfNeeded() {
                    return
                }
                if server?.account == nil {
                    appState.showSettings = true
                } else {
                    let nextKey = try? await appModel.reloadThread(
                        key: thread.key,
                        launchConfig: reloadLaunchConfig(),
                        cwdOverride: thread.info.cwd
                    )
                    if let nextKey {
                        appModel.store.setActiveThread(
                            key: nextKey
                        )
                    }
                }
            }
        } label: {
            reloadButtonLabel
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || server?.isConnected != true)
    }

    @ViewBuilder
    private var reloadButtonLabel: some View {
        if isReloading {
            ProgressView()
                .scaleEffect(0.7)
                .tint(LitterTheme.accent)
        } else {
            Image(systemName: "arrow.clockwise")
                .font(LitterFont.styled(size: 16, weight: .semibold))
                .foregroundColor(server?.isConnected == true ? LitterTheme.accent : LitterTheme.textMuted)
        }
    }

    private var infoButton: some View {
        Button {
            onInfo?()
        } label: {
            Image(systemName: "info.circle")
                .font(LitterFont.styled(size: 16, weight: .semibold))
                .foregroundColor(LitterTheme.accent)
        }
        .accessibilityIdentifier("header.infoButton")
    }

    private func handleRemoteLoginIfNeeded() async -> Bool {
        guard let server, !server.isLocal else {
            return false
        }
        guard server.account == nil else {
            return false
        }
        do {
            let authURL = try await appModel.client.startRemoteSshOauthLogin(
                serverId: server.serverId
            )
            if let url = URL(string: authURL) {
                await MainActor.run {
                    remoteAuthSession = RemoteAuthSession(url: url)
                }
            }
        } catch {}
        return true
    }

    private func reloadLaunchConfig() -> AppThreadLaunchConfig {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = pendingModel.isEmpty ? nil : pendingModel
        return AppThreadLaunchConfig(
            model: resolvedModel,
            approvalPolicy: appState.launchApprovalPolicy(for: thread.key),
            sandbox: appState.launchSandboxMode(for: thread.key),
            developerInstructions: nil,
            persistExtendedHistory: true
        )
    }
}

private struct RemoteAuthSession: Identifiable {
    let id = UUID()
    let url: URL
}

struct InlineModelSelectorView: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    /// `nil` indicates the view is being used before a thread exists (home
    /// composer). In that case, plan-mode selection is stored as a pending
    /// app-state preference that the caller applies after `startThread`.
    var threadKey: ThreadKey?
    var collaborationMode: AppModeKind = .default
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false
    var onDismiss: () -> Void

    private var currentModel: ModelInfo? {
        if let match = models.first(where: { $0.id == selectedModel }) {
            return match
        }
        // When shown from the home composer, `selectedModel` may be empty
        // because the user hasn't picked yet. Fall back to the default
        // model so the reasoning effort row has something to render.
        return models.first(where: { $0.isDefault }) ?? models.first
    }

    /// Effective collaboration mode: live thread value when we have one,
    /// otherwise the pre-thread pending selection tracked on `appState`.
    private var effectiveCollaborationMode: AppModeKind {
        threadKey == nil ? appState.pendingCollaborationMode : collaborationMode
    }

    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: threadKey) ?? effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: threadKey) ?? effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox) == .fullAccess
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        Button {
                            selectedModel = model.id
                            reasoningEffort = model.defaultReasoningEffort.wireValue
                            // Auto-dismiss only in the thread-scoped popover
                            // context. In the home sheet (no thread yet) we
                            // let the user pick a model AND change plan or
                            // permissions before hitting Done.
                            if threadKey != nil { onDismiss() }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.displayName)
                                            .litterFont(.footnote)
                                            .foregroundColor(LitterTheme.textPrimary)
                                        if model.isDefault {
                                            Text("default")
                                                .litterFont(.caption2, weight: .medium)
                                                .foregroundColor(LitterTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(LitterTheme.accent.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(model.description)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                if model.id == selectedModel {
                                    Image(systemName: "checkmark")
                                        .litterFont(size: 12, weight: .medium)
                                        .foregroundColor(LitterTheme.accent)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                        }
                        if model.id != models.last?.id {
                            Divider().background(LitterTheme.separator).padding(.leading, 16)
                        }
                    }
                }
            }
            .frame(maxHeight: 260)

            if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                Divider().background(LitterTheme.separator).padding(.horizontal, 12)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(info.supportedReasoningEfforts) { effort in
                            Button {
                                reasoningEffort = effort.reasoningEffort.wireValue
                                onDismiss()
                            } label: {
                                Text(effort.reasoningEffort.wireValue)
                                    .litterFont(.caption2, weight: .medium)
                                    .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }

            Divider().background(LitterTheme.separator).padding(.horizontal, 12)

            HStack(spacing: 6) {
                Button {
                    let current = effectiveCollaborationMode
                    let next: AppModeKind = current == .plan ? .default : .plan
                    if let threadKey {
                        Task {
                            try? await appModel.store.setThreadCollaborationMode(
                                key: threadKey, mode: next
                            )
                        }
                    } else {
                        appState.pendingCollaborationMode = next
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Plan")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(effectiveCollaborationMode == .plan ? .black : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(effectiveCollaborationMode == .plan ? LitterTheme.accent : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                Button {
                    fastMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Fast")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(fastMode ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fastMode ? LitterTheme.warning : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                Button {
                    if isFullAccess {
                        appState.setPermissions(approvalPolicy: "on-request", sandboxMode: "workspace-write", for: threadKey)
                    } else {
                        appState.setPermissions(approvalPolicy: "never", sandboxMode: "danger-full-access", for: threadKey)
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isFullAccess ? "lock.open.fill" : "lock.fill")
                            .litterFont(size: 9, weight: .semibold)
                        Text(isFullAccess ? "Full Access" : "Supervised")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(isFullAccess ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(isFullAccess ? LitterTheme.danger : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }

                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct InAppSafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

struct ModelSelectorSheet: View {
    let models: [ModelInfo]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    @AppStorage("fastMode") private var fastMode = false

    private var currentModel: ModelInfo? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    selectedModel = model.id
                    reasoningEffort = model.defaultReasoningEffort.wireValue
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .litterFont(.footnote)
                                    .foregroundColor(LitterTheme.textPrimary)
                                if model.isDefault {
                                    Text("default")
                                        .litterFont(.caption2, weight: .medium)
                                        .foregroundColor(LitterTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(LitterTheme.accent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(model.description)
                                .litterFont(.caption2)
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if model.id == selectedModel {
                            Image(systemName: "checkmark")
                                .litterFont(size: 12, weight: .medium)
                                .foregroundColor(LitterTheme.accent)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
                Divider().background(LitterTheme.separator).padding(.leading, 20)
            }

            if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(info.supportedReasoningEfforts) { effort in
                            Button {
                                reasoningEffort = effort.reasoningEffort.wireValue
                            } label: {
                                Text(effort.reasoningEffort.wireValue)
                                    .litterFont(.caption2, weight: .medium)
                                    .foregroundColor(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort.wireValue == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

            Divider().background(LitterTheme.separator).padding(.leading, 20)

            HStack(spacing: 6) {
                Button {
                    fastMode.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bolt.fill")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Fast")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(fastMode ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(fastMode ? LitterTheme.warning : LitterTheme.surfaceLight)
                    .clipShape(Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            }
        }
        .padding(.top, 20)
        .background(.ultraThinMaterial)
    }
}

#if DEBUG
#Preview("Header") {
    let appModel = LitterPreviewData.makeConversationAppModel()
    LitterPreviewScene(appModel: appModel) {
        HeaderView(thread: appModel.snapshot!.threads[0])
    }
}
#endif
