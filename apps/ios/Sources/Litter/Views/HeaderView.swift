import SwiftUI

struct HeaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppModel.self) private var appModel
    let thread: AppThreadSnapshot
    let onBack: () -> Void
    @State private var isReloading = false
    @State private var pulsing = false
    @AppStorage("fastMode") private var fastMode = false

    var topInset: CGFloat = 0

    private var server: AppServerSnapshot? {
        appModel.snapshot?.serverSnapshot(for: thread.key.serverId)
    }

    private var availableModels: [Model] {
        appModel.availableModels(for: thread.key.serverId)
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .litterFont(size: 16, weight: .medium)
                        .foregroundColor(LitterTheme.textSecondary)
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier())
                }
                .accessibilityIdentifier("header.homeButton")

                Spacer(minLength: 0)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.showModelSelector.toggle()
                    }
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
                                    .litterFont(size: 10, weight: .semibold)
                                    .foregroundColor(LitterTheme.warning)
                            }
                            Text(sessionModelLabel)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(sessionReasoningLabel)
                                .foregroundColor(LitterTheme.textSecondary)
                            Image(systemName: "chevron.down")
                                .litterFont(size: 10, weight: .semibold)
                                .foregroundColor(LitterTheme.textSecondary)
                                .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
                        }
                        .litterFont(.subheadline, weight: .semibold)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                        Text(sessionDirectoryLabel)
                            .litterFont(.caption2, weight: .semibold)
                            .foregroundColor(LitterTheme.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .modifier(GlassRectModifier(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("header.modelPickerButton")

                Spacer(minLength: 0)

                reloadButton
            }
            .padding(.horizontal, 16)
            .padding(.top, topInset)
            .padding(.bottom, 4)

            if appState.showModelSelector {
                InlineModelSelectorView(
                    models: availableModels,
                    selectedModel: selectedModelBinding,
                    reasoningEffort: reasoningEffortBinding,
                    onDismiss: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.showModelSelector = false
                    }
                }
                )
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background(
            LinearGradient(
                colors: LitterTheme.headerScrim,
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.bottom, -30)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        )
        .task(id: thread.key) {
            await loadModelsIfNeeded()
        }
    }

    private var shouldPulse: Bool {
        guard let health = server?.health else { return false }
        return health == .connecting || health == .unresponsive
    }

    private var statusDotColor: Color {
        guard let server else {
            return LitterTheme.textMuted
        }
        switch server.health {
        case .connecting, .unresponsive:
            return .orange
        case .connected:
            switch server.account {
            case .chatgpt?, .apiKey?:
                return LitterTheme.success
            case nil:
                return LitterTheme.danger
            }
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

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                defer { isReloading = false }
                if server?.account == nil {
                    appState.showSettings = true
                } else {
                    _ = try? await appModel.rpc.threadList(
                        serverId: thread.key.serverId,
                        params: ThreadListParams(
                            cursor: nil,
                            limit: nil,
                            sortKey: nil,
                            modelProviders: nil,
                            sourceKinds: nil,
                            archived: nil,
                            cwd: nil,
                            searchTerm: nil
                        )
                    )
                    let response = try? await appModel.rpc.threadResume(
                        serverId: thread.key.serverId,
                        params: reloadLaunchConfig().threadResumeParams(
                            threadId: thread.key.threadId,
                            cwdOverride: thread.info.cwd
                        )
                    )
                    if let response {
                        appModel.store.setActiveThread(
                            key: ThreadKey(serverId: thread.key.serverId, threadId: response.thread.id)
                        )
                    }
                    await appModel.refreshSnapshot()
                }
            }
        } label: {
            Group {
                if isReloading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(LitterTheme.accent)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .litterFont(size: 16, weight: .semibold)
                        .foregroundColor(server?.isConnected == true ? LitterTheme.accent : LitterTheme.textMuted)
                }
            }
            .frame(width: 44, height: 44)
            .modifier(GlassCircleModifier())
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || server?.isConnected != true)
    }

    private func reloadLaunchConfig() -> AppThreadLaunchConfig {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedModel = pendingModel.isEmpty ? nil : pendingModel
        return AppThreadLaunchConfig(
            model: resolvedModel,
            approvalPolicy: AskForApproval(wireValue: appState.approvalPolicy),
            sandbox: SandboxMode(wireValue: appState.sandboxMode),
            developerInstructions: nil,
            persistExtendedHistory: false
        )
    }

}

struct InlineModelSelectorView: View {
    let models: [Model]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    @AppStorage("fastMode") private var fastMode = false
    var onDismiss: () -> Void

    private var currentModel: Model? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        Button {
                            selectedModel = model.id
                            reasoningEffort = model.defaultReasoningEffort.wireValue
                            onDismiss()
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
            .frame(maxHeight: 320)

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
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GlassRectModifier(cornerRadius: 16))
    }
}

struct ModelSelectorSheet: View {
    let models: [Model]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    @AppStorage("fastMode") private var fastMode = false

    private var currentModel: Model? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
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

            Spacer()
        }
        .padding(.top, 20)
        .background(.ultraThinMaterial)
    }
}

#if DEBUG
#Preview("Header") {
    let appModel = LitterPreviewData.makeConversationAppModel()
    LitterPreviewScene(appModel: appModel) {
        HeaderView(
            thread: appModel.snapshot!.threads[0],
            onBack: {}
        )
    }
}
#endif
