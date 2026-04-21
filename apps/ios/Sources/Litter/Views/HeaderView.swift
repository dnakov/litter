import SafariServices
import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    @State private var pulsing = false
    @State private var showModelBrowser = false
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
                    if let provider = sessionProviderLabel {
                        Text(provider)
                            .foregroundColor(.black)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(LitterTheme.accent.opacity(0.9))
                            .clipShape(Capsule())
                    }
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
            ConversationModelPickerPanel(
                thread: thread,
                onBrowseAllModels: {
                    appState.showModelSelector = false
                    showModelBrowser = true
                }
            )
                .presentationCompactAdaptation(.popover)
        }
        .sheet(isPresented: $showModelBrowser) {
            ModelSelectorSheet(
                models: availableModels,
                selectedModel: selectedModelBinding,
                reasoningEffort: reasoningEffortBinding,
                thread: thread
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
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
        let pendingModel = appState.selectedModel(for: thread.key.serverId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingModel.isEmpty { return pendingModel }

        let threadModel = (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty { return threadModel }

        return "litter"
    }

    private var sessionProviderLabel: String? {
        let pendingModel = appState.selectedModel(for: thread.key.serverId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let pendingProvider = providerLabel(for: pendingModel) {
            return pendingProvider
        }
        let provider = thread.info.modelProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !provider.isEmpty {
            return provider
        }
        return providerLabel(for: thread.resolvedModel)
    }

    private var sessionReasoningLabel: String {
        let pendingReasoning = appState.reasoningEffort(for: thread.key.serverId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
                let pending = appState.selectedModel(for: thread.key.serverId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.setSelectedModel($0, for: thread.key.serverId) }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort(for: thread.key.serverId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.setReasoningEffort($0, for: thread.key.serverId) }
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
    var onBrowseAllModels: (() -> Void)? = nil

    private var availableModels: [ModelInfo] {
        appModel.availableModels(for: thread.key.serverId)
    }

    var body: some View {
        InlineModelSelectorView(
            models: availableModels,
            selectedModel: selectedModelBinding,
            reasoningEffort: reasoningEffortBinding,
            thread: thread,
            threadKey: thread.key,
            collaborationMode: thread.collaborationMode,
            effectiveApprovalPolicy: thread.effectiveApprovalPolicy,
            effectiveSandboxPolicy: thread.effectiveSandboxPolicy,
            onBrowseAllModels: onBrowseAllModels,
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
                let pending = appState.selectedModel(for: thread.key.serverId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return (thread.model ?? thread.info.model ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            },
            set: { appState.setSelectedModel($0, for: thread.key.serverId) }
        )
    }

    private var reasoningEffortBinding: Binding<String> {
        Binding(
            get: {
                let pending = appState.reasoningEffort(for: thread.key.serverId)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !pending.isEmpty { return pending }
                return thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            },
            set: { appState.setReasoningEffort($0, for: thread.key.serverId) }
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
        let pendingModel = appState.selectedModel(for: thread.key.serverId)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
    var thread: AppThreadSnapshot? = nil
    var threadKey: ThreadKey
    var collaborationMode: AppModeKind = .default
    var effectiveApprovalPolicy: AppAskForApproval?
    var effectiveSandboxPolicy: AppSandboxPolicy?
    @Environment(AppModel.self) private var appModel
    @Environment(AppState.self) private var appState
    @AppStorage("fastMode") private var fastMode = false
    var onBrowseAllModels: (() -> Void)? = nil
    var onDismiss: () -> Void

    private var currentModel: ModelInfo? {
        models.first { $0.id == selectedModel }
    }

    private var currentThread: AppThreadSnapshot? {
        appModel.snapshot?.threads.first { $0.key == threadKey } ?? thread
    }

    private var workspaceModels: [ModelInfo] {
        modelHistory(
            matching: { candidate in
                candidate.key.serverId == threadKey.serverId
                    && candidate.info.cwd == currentThread?.info.cwd
            },
            limit: 4,
            excluding: [selectedModel]
        )
    }

    private var recentModels: [ModelInfo] {
        modelHistory(
            matching: { $0.key.serverId == threadKey.serverId },
            limit: 6,
            excluding: Set(workspaceModels.map(\.id)).union([selectedModel])
        )
    }

    private var serverDefaultModel: ModelInfo? {
        models.first(where: \.isDefault)
    }

    private var isFullAccess: Bool {
        let approval = appState.launchApprovalPolicy(for: threadKey) ?? effectiveApprovalPolicy
        let sandbox = appState.turnSandboxPolicy(for: threadKey) ?? effectiveSandboxPolicy
        return threadPermissionPreset(approvalPolicy: approval, sandboxPolicy: sandbox) == .fullAccess
    }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if models.isEmpty {
                    Text("Loading models…")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 20)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let serverDefaultModel {
                                quickSection(title: "Server Default", models: [serverDefaultModel])
                            }

                            if !workspaceModels.isEmpty {
                                quickSection(title: "This Workspace", models: workspaceModels)
                            }

                            if !recentModels.isEmpty {
                                quickSection(title: "Recent", models: recentModels)
                            }

                            if let onBrowseAllModels {
                                Button(action: onBrowseAllModels) {
                                    HStack {
                                        Text("Browse all models")
                                            .litterFont(.footnote, weight: .medium)
                                            .foregroundColor(LitterTheme.textPrimary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(LitterTheme.textMuted)
                                            .font(.system(size: 11, weight: .semibold))
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(LitterTheme.surfaceLight)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 12)
                    }
                }
            }
            .frame(maxHeight: 300)

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
                    let next: AppModeKind = collaborationMode == .plan ? .default : .plan
                    Task {
                        try? await appModel.store.setThreadCollaborationMode(
                            key: threadKey, mode: next
                        )
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "doc.text")
                            .litterFont(size: 9, weight: .semibold)
                        Text("Plan")
                            .litterFont(.caption2, weight: .medium)
                    }
                    .foregroundColor(collaborationMode == .plan ? .black : LitterTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(collaborationMode == .plan ? LitterTheme.accent : LitterTheme.surfaceLight)
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

    @ViewBuilder
    private func quickSection(title: String, models: [ModelInfo]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .litterFont(.caption2, weight: .semibold)
                .foregroundColor(LitterTheme.textMuted)

            VStack(spacing: 0) {
                ForEach(models) { model in
                    Button {
                        selectedModel = model.id
                        reasoningEffort = model.defaultReasoningEffort.wireValue
                        onDismiss()
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(model.displayName.ifEmpty(model.id))
                                        .litterFont(.footnote)
                                        .foregroundColor(LitterTheme.textPrimary)
                                    if let provider = providerLabel(for: model.id) {
                                        Text(provider)
                                            .litterFont(.caption2, weight: .medium)
                                            .foregroundColor(.black)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(LitterTheme.accent.opacity(0.9))
                                            .clipShape(Capsule())
                                    }
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
                                if !model.description.isEmpty {
                                    Text(model.description)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textSecondary)
                                        .lineLimit(2)
                                }
                            }
                            Spacer()
                            if model.id == selectedModel {
                                Image(systemName: "checkmark")
                                    .litterFont(size: 12, weight: .medium)
                                    .foregroundColor(LitterTheme.accent)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)

                    if model.id != models.last?.id {
                        Divider().background(LitterTheme.separator).padding(.leading, 12)
                    }
                }
            }
            .background(LitterTheme.surfaceLight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func modelHistory(
        matching: (AppThreadSnapshot) -> Bool,
        limit: Int,
        excluding: Set<String>
    ) -> [ModelInfo] {
        guard let snapshot = appModel.snapshot else { return [] }
        var seen = Set<String>()
        var results: [ModelInfo] = []
        let sortedThreads = snapshot.threads.sorted { ($0.info.updatedAt ?? 0) > ($1.info.updatedAt ?? 0) }
        for candidate in sortedThreads where matching(candidate) {
            let modelId = candidate.resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty, !excluding.contains(modelId), seen.insert(modelId).inserted else { continue }
            guard let model = models.first(where: { $0.id == modelId }) else { continue }
            results.append(model)
            if results.count == limit {
                break
            }
        }
        return results
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
    var thread: AppThreadSnapshot? = nil
    @AppStorage("fastMode") private var fastMode = false
    @Environment(AppModel.self) private var appModel
    @State private var searchText = ""

    private var currentModel: ModelInfo? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(LitterTheme.textMuted)
                    TextField("Search models or providers", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                        .foregroundColor(LitterTheme.textPrimary)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(LitterTheme.surfaceLight)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .padding(.horizontal, 16)
                .padding(.top, 16)

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(modelSections(), id: \.title) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .litterFont(.caption2, weight: .semibold)
                                    .foregroundColor(LitterTheme.textMuted)
                                VStack(spacing: 0) {
                                    ForEach(section.models) { model in
                                        modelRow(model)
                                        if model.id != section.models.last?.id {
                                            Divider().background(LitterTheme.separator).padding(.leading, 12)
                                        }
                                    }
                                }
                                .background(LitterTheme.surfaceLight)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }

                if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                    Divider().background(LitterTheme.separator).padding(.horizontal, 12)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(info.supportedReasoningEfforts) { effort in
                                Button {
                                    reasoningEffort = effort.reasoningEffort.wireValue
                                } label: {
                                    Text(effort.reasoningEffort.wireValue)
                                        .litterFont(.caption2, weight: .medium)
                                        .foregroundColor(
                                            effort.reasoningEffort.wireValue == reasoningEffort
                                                ? LitterTheme.textOnAccent
                                                : LitterTheme.textPrimary
                                        )
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 5)
                                        .background(
                                            effort.reasoningEffort.wireValue == reasoningEffort
                                                ? LitterTheme.accent
                                                : LitterTheme.surfaceLight
                                        )
                                        .clipShape(Capsule())
                                }
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                    }
                }

                Divider().background(LitterTheme.separator).padding(.horizontal, 12)

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
            .background(.ultraThinMaterial)
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func modelSections() -> [ModelSection] {
        let filtered = filteredModels()
        var sections: [ModelSection] = []

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let workspace = modelHistory(
                matching: {
                    $0.key.serverId == thread?.key.serverId
                        && $0.info.cwd == thread?.info.cwd
                },
                limit: 6,
                excluding: [selectedModel]
            )
            if !workspace.isEmpty {
                sections.append(ModelSection(title: "This Workspace", models: workspace))
            }

            let recent = modelHistory(
                matching: { $0.key.serverId == thread?.key.serverId },
                limit: 8,
                excluding: Set(workspace.map(\.id)).union([selectedModel])
            )
            if !recent.isEmpty {
                sections.append(ModelSection(title: "Recent", models: recent))
            }
        }

        for (provider, providerModels) in groupModelsByProvider(filtered) {
            sections.append(ModelSection(title: provider, models: providerModels))
        }

        if sections.isEmpty, !filtered.isEmpty {
            sections.append(ModelSection(title: "All Models", models: filtered))
        }

        return sections
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        Button {
            selectedModel = model.id
            reasoningEffort = model.defaultReasoningEffort.wireValue
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.displayName.ifEmpty(model.id))
                            .litterFont(.footnote)
                            .foregroundColor(LitterTheme.textPrimary)
                        if let provider = providerLabel(for: model.id) {
                            Text(provider)
                                .litterFont(.caption2, weight: .medium)
                                .foregroundColor(.black)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(LitterTheme.accent.opacity(0.9))
                                .clipShape(Capsule())
                        }
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
                    if !model.description.isEmpty {
                        Text(model.description)
                            .litterFont(.caption2)
                            .foregroundColor(LitterTheme.textSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if model.id == selectedModel {
                    Image(systemName: "checkmark")
                        .litterFont(size: 12, weight: .medium)
                        .foregroundColor(LitterTheme.accent)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
    }

    private func filteredModels() -> [ModelInfo] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sorted = models.sorted {
            if $0.isDefault != $1.isDefault {
                return $0.isDefault && !$1.isDefault
            }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        guard !query.isEmpty else { return sorted }
        return sorted.filter { model in
            model.displayName.localizedCaseInsensitiveContains(query)
                || model.id.localizedCaseInsensitiveContains(query)
                || model.description.localizedCaseInsensitiveContains(query)
                || (providerLabel(for: model.id)?.localizedCaseInsensitiveContains(query) == true)
        }
    }

    private func modelHistory(
        matching: (AppThreadSnapshot) -> Bool,
        limit: Int,
        excluding: Set<String>
    ) -> [ModelInfo] {
        guard let snapshot = appModel.snapshot else { return [] }
        var seen = Set<String>()
        var results: [ModelInfo] = []
        let sortedThreads = snapshot.threads.sorted { ($0.info.updatedAt ?? 0) > ($1.info.updatedAt ?? 0) }
        for candidate in sortedThreads where matching(candidate) {
            let modelId = candidate.resolvedModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !modelId.isEmpty, !excluding.contains(modelId), seen.insert(modelId).inserted else { continue }
            guard let model = models.first(where: { $0.id == modelId }) else { continue }
            results.append(model)
            if results.count == limit {
                break
            }
        }
        return results
    }
}

private struct ModelSection {
    let title: String
    let models: [ModelInfo]
}

func groupModelsByProvider(_ models: [ModelInfo]) -> [(String, [ModelInfo])] {
    let grouped = Dictionary(grouping: models) { providerLabel(for: $0.id) ?? "Other" }
    return grouped.keys.sorted().map { provider in
        (
            provider,
            grouped[provider, default: []].sorted {
                if $0.isDefault != $1.isDefault {
                    return $0.isDefault && !$1.isDefault
                }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
    }
}

private func providerLabel(for modelId: String) -> String? {
    let trimmed = modelId.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if let separator = trimmed.firstIndex(of: ":") {
        let provider = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        return provider.isEmpty ? nil : provider
    }
    return nil
}

private extension String {
    func ifEmpty(_ fallback: String) -> String {
        isEmpty ? fallback : self
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
