import SwiftUI
import Inject

struct HeaderView: View {
    @ObserveInjection var inject
    @Environment(AppState.self) private var appState
    let thread: ThreadState
    let connection: ServerConnection
    let serverManager: ServerManager
    let onBack: () -> Void
    @State private var isReloading = false
    @State private var showOAuth = false
    @State private var pulsing = false

    var topInset: CGFloat = 0

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .medium))
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
                            Text(sessionModelLabel)
                                .foregroundColor(LitterTheme.textPrimary)
                            Text(sessionReasoningLabel)
                                .foregroundColor(LitterTheme.textSecondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(LitterTheme.textSecondary)
                                .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
                        }
                        .font(LitterFont.styled(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                        Text(sessionDirectoryLabel)
                            .font(LitterFont.styled(.caption2, weight: .semibold))
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
                    models: connection.models,
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
        .onChange(of: connection.oauthURL) { _, url in
            showOAuth = url != nil
        }
        .onChange(of: connection.loginCompleted) { _, completed in
            if completed == true {
                showOAuth = false
            }
        }
        .sheet(isPresented: $showOAuth) {
            if let url = connection.oauthURL {
                NavigationStack {
                    OAuthWebView(url: url, onCallbackIntercepted: { callbackURL in
                        connection.forwardOAuthCallback(callbackURL)
                    }) {
                        Task { await connection.cancelLogin() }
                    }
                    .ignoresSafeArea()
                    .navigationTitle("Login with ChatGPT")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button("Cancel") {
                                Task { await connection.cancelLogin() }
                                showOAuth = false
                            }
                            .foregroundColor(LitterTheme.danger)
                        }
                    }
                }
            }
        }
        .enableInjection()
    }

    private var shouldPulse: Bool {
        connection.connectionHealth == .connecting || connection.connectionHealth == .unresponsive
    }

    private var statusDotColor: Color {
        switch connection.connectionHealth {
        case .disconnected:
            return LitterTheme.danger
        case .connecting, .unresponsive:
            return .orange
        case .connected:
            switch connection.authStatus {
            case .chatgpt, .apiKey: return LitterTheme.success
            case .notLoggedIn: return LitterTheme.danger
            case .unknown: return LitterTheme.textMuted
            }
        }
    }

    private var sessionModelLabel: String {
        let pendingModel = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingModel.isEmpty { return pendingModel }

        let threadModel = thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !threadModel.isEmpty { return threadModel }

        return "litter"
    }

    private var sessionReasoningLabel: String {
        let pendingReasoning = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !pendingReasoning.isEmpty { return pendingReasoning }

        let threadReasoning = thread.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty { return threadReasoning }

        return "default"
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = thread.cwd.trimmingCharacters(in: .whitespacesAndNewlines)
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
                return thread.model.trimmingCharacters(in: .whitespacesAndNewlines)
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
        guard connection.isConnected, !connection.modelsLoaded else { return }
        do {
            let resp = try await connection.listModels()
            connection.models = resp.data
            connection.modelsLoaded = true
        } catch {}
    }

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                if connection.authStatus == .notLoggedIn {
                    await connection.logout()
                    await connection.loginWithChatGPT()
                } else {
                    await serverManager.refreshAllSessions()
                    await serverManager.syncActiveThreadFromServer()
                }
                isReloading = false
            }
        } label: {
            Group {
                if isReloading {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(LitterTheme.accent)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(connection.isConnected ? LitterTheme.accent : LitterTheme.textMuted)
                }
            }
            .frame(width: 44, height: 44)
            .modifier(GlassCircleModifier())
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || !connection.isConnected)
    }

}

struct InlineModelSelectorView: View {
    let models: [CodexModel]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String
    var onDismiss: () -> Void

    private var currentModel: CodexModel? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        Button {
                            selectedModel = model.id
                            reasoningEffort = model.defaultReasoningEffort
                            onDismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.displayName)
                                            .font(LitterFont.styled(.footnote))
                                            .foregroundColor(LitterTheme.textPrimary)
                                        if model.isDefault {
                                            Text("default")
                                                .font(LitterFont.styled(.caption2, weight: .medium))
                                                .foregroundColor(LitterTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(LitterTheme.accent.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(model.description)
                                        .font(LitterFont.styled(.caption2))
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                if model.id == selectedModel {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 12, weight: .medium))
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
                                reasoningEffort = effort.reasoningEffort
                                onDismiss()
                            } label: {
                                Text(effort.reasoningEffort)
                                    .font(LitterFont.styled(.caption2, weight: .medium))
                                    .foregroundColor(effort.reasoningEffort == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
            }
        }
        .padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(GlassRectModifier(cornerRadius: 16))
    }
}

struct ModelSelectorSheet: View {
    let models: [CodexModel]
    @Binding var selectedModel: String
    @Binding var reasoningEffort: String

    private var currentModel: CodexModel? {
        models.first { $0.id == selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    selectedModel = model.id
                    reasoningEffort = model.defaultReasoningEffort
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .font(LitterFont.styled(.footnote))
                                    .foregroundColor(LitterTheme.textPrimary)
                                if model.isDefault {
                                    Text("default")
                                        .font(LitterFont.styled(.caption2, weight: .medium))
                                        .foregroundColor(LitterTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(LitterTheme.accent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(model.description)
                                .font(LitterFont.styled(.caption2))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if model.id == selectedModel {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .medium))
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
                                reasoningEffort = effort.reasoningEffort
                            } label: {
                                Text(effort.reasoningEffort)
                                    .font(LitterFont.styled(.caption2, weight: .medium))
                                    .foregroundColor(effort.reasoningEffort == reasoningEffort ? LitterTheme.textOnAccent : LitterTheme.textPrimary)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort == reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                }
            }

            Spacer()
        }
        .padding(.top, 20)
        .background(.ultraThinMaterial)
    }
}

#if DEBUG
#Preview("Header") {
    let manager = LitterPreviewData.makeServerManager()
    return LitterPreviewScene(serverManager: manager) {
        HeaderView(
            thread: manager.activeThread!,
            connection: manager.activeConnection!,
            serverManager: manager,
            onBack: {}
        )
    }
}
#endif
