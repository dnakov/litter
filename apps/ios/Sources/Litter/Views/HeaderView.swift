import SwiftUI
import Inject

struct HeaderView: View {
    private static let contextBaselineTokens: Int64 = 12_000

    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var isReloading = false

    var topInset: CGFloat = 0

    private var activeConn: ServerConnection? {
        serverManager.activeConnection
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(alignment: .center, spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        appState.sidebarOpen.toggle()
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color(hex: "#999999"))
                        .frame(width: 44, height: 44)
                        .modifier(GlassCircleModifier())
                }
                .accessibilityIdentifier("header.sidebarButton")

                Spacer(minLength: 0)

                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.showModelSelector.toggle()
                    }
                } label: {
                    VStack(spacing: 2) {
                        HStack(spacing: 6) {
                            Text(sessionModelLabel)
                                .foregroundColor(.white)
                            Text(sessionReasoningLabel)
                                .foregroundColor(LitterTheme.textSecondary)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(LitterTheme.textSecondary)
                                .rotationEffect(.degrees(appState.showModelSelector ? 180 : 0))
                        }
                        .font(LitterFont.monospaced(.subheadline, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                        HStack(spacing: 6) {
                            Text(sessionDirectoryLabel)
                                .font(LitterFont.monospaced(.caption2, weight: .semibold))
                                .foregroundColor(LitterTheme.textSecondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            ContextRingView(percent: Int(sessionContextPercent ?? 100), tint: sessionContextTint)
                        }
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
                InlineModelSelectorView(onDismiss: {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                        appState.showModelSelector = false
                    }
                })
                .padding(.horizontal, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .top)))
            }
        }
        .background(
            LinearGradient(
                colors: [.black.opacity(0.5), .black.opacity(0.2), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.bottom, -30)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        )
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            syncSelectionFromActiveThread()
            Task { await loadModelsIfNeeded() }
        }
        .onChange(of: serverManager.activeThread?.model) { _, _ in
            syncSelectionFromActiveThread()
        }
        .onChange(of: serverManager.activeThread?.reasoningEffort) { _, _ in
            syncSelectionFromActiveThread()
        }
        .onChange(of: serverManager.activeThread?.cwd) { _, _ in
            syncSelectionFromActiveThread()
        }
        .task {
            syncSelectionFromActiveThread()
            await loadModelsIfNeeded()
        }
        .enableInjection()
    }

    private var sessionModelLabel: String {
        let selected = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }

        let threadModel = serverManager.activeThread?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadModel.isEmpty { return threadModel }

        return "litter"
    }

    private var sessionReasoningLabel: String {
        let selected = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty { return selected }

        let threadReasoning = serverManager.activeThread?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty { return threadReasoning }

        return "default"
    }

    private var sessionContextTint: Color {
        guard let percent = sessionContextPercent else {
            return LitterTheme.textSecondary
        }
        switch percent {
        case ...15:
            return LitterTheme.danger
        case ...35:
            return LitterTheme.warning
        default:
            return LitterTheme.accentStrong
        }
    }

    private var sessionDirectoryLabel: String {
        let currentDirectory = serverManager.activeThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !currentDirectory.isEmpty {
            return abbreviateRemoteHomePath(currentDirectory)
        }

        let appDirectory = appState.currentCwd.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appDirectory.isEmpty {
            return abbreviateRemoteHomePath(appDirectory)
        }

        return "~"
    }

    private var sessionContextPercent: Int64? {
        guard let thread = serverManager.activeThread,
              let contextWindow = thread.modelContextWindow else {
            return nil
        }

        let totalTokens = thread.contextTokensUsed ?? Self.contextBaselineTokens
        return percentOfContextWindowRemaining(
            totalTokens: totalTokens,
            contextWindow: contextWindow
        )
    }

    private func loadModelsIfNeeded() async {
        syncSelectionFromActiveThread()

        guard let conn = activeConn, conn.isConnected, !conn.modelsLoaded else { return }
        do {
            let resp = try await conn.listModels()
            conn.models = resp.data
            conn.modelsLoaded = true
            if appState.selectedModel.isEmpty {
                if let defaultModel = resp.data.first(where: { $0.isDefault }) {
                    appState.selectedModel = defaultModel.id
                    appState.reasoningEffort = defaultModel.defaultReasoningEffort
                } else if let first = resp.data.first {
                    appState.selectedModel = first.id
                    appState.reasoningEffort = first.defaultReasoningEffort
                }
            }
        } catch {}
    }

    private func syncSelectionFromActiveThread() {
        let threadModel = serverManager.activeThread?.model.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadModel.isEmpty && appState.selectedModel != threadModel {
            appState.selectedModel = threadModel
        }

        let threadReasoning = serverManager.activeThread?.reasoningEffort?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadReasoning.isEmpty && appState.reasoningEffort != threadReasoning {
            appState.reasoningEffort = threadReasoning
        }

        let threadCwd = serverManager.activeThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !threadCwd.isEmpty && appState.currentCwd != threadCwd {
            appState.currentCwd = threadCwd
        }
    }

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                await serverManager.refreshAllSessions()
                await serverManager.syncActiveThreadFromServer()
                syncSelectionFromActiveThread()
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
                        .foregroundColor(serverManager.hasAnyConnection ? LitterTheme.accent : LitterTheme.textMuted)
                }
            }
            .frame(width: 44, height: 44)
            .modifier(GlassCircleModifier())
        }
        .accessibilityIdentifier("header.reloadButton")
        .disabled(isReloading || !serverManager.hasAnyConnection)
    }

    private func percentOfContextWindowRemaining(totalTokens: Int64, contextWindow: Int64) -> Int64 {
        let baseline = Self.contextBaselineTokens
        guard contextWindow > baseline else { return 0 }

        let effectiveWindow = contextWindow - baseline
        let usedTokens = max(0, totalTokens - baseline)
        let remainingTokens = max(0, effectiveWindow - usedTokens)
        let remainingFraction = Double(remainingTokens) / Double(effectiveWindow)
        let percent = Int64((remainingFraction * 100).rounded())
        return min(max(percent, 0), 100)
    }

    private func abbreviateRemoteHomePath(_ path: String) -> String {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return "~" }

        if let abbreviated = abbreviateUnixHomePrefix(trimmedPath, basePrefix: "/Users") {
            return abbreviated
        }
        if let abbreviated = abbreviateUnixHomePrefix(trimmedPath, basePrefix: "/home") {
            return abbreviated
        }
        return trimmedPath
    }

    private func abbreviateUnixHomePrefix(_ path: String, basePrefix: String) -> String? {
        let prefix = basePrefix + "/"
        guard path.hasPrefix(prefix) else { return nil }

        let remainder = path.dropFirst(prefix.count)
        guard let slashIndex = remainder.firstIndex(of: "/") else {
            return "~"
        }

        let suffix = remainder[slashIndex...]
        return "~" + suffix
    }
}

struct InlineModelSelectorView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    var onDismiss: () -> Void

    private var models: [CodexModel] {
        serverManager.activeConnection?.models ?? []
    }

    private var currentModel: CodexModel? {
        models.first { $0.id == appState.selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(models) { model in
                        Button {
                            appState.selectedModel = model.id
                            appState.reasoningEffort = model.defaultReasoningEffort
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(model.displayName)
                                            .font(LitterFont.monospaced(.footnote))
                                            .foregroundColor(.white)
                                        if model.isDefault {
                                            Text("default")
                                                .font(LitterFont.monospaced(.caption2, weight: .medium))
                                                .foregroundColor(LitterTheme.accent)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1)
                                                .background(LitterTheme.accent.opacity(0.15))
                                                .clipShape(Capsule())
                                        }
                                    }
                                    Text(model.description)
                                        .font(LitterFont.monospaced(.caption2))
                                        .foregroundColor(LitterTheme.textSecondary)
                                }
                                Spacer()
                                if model.id == appState.selectedModel {
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
                                appState.reasoningEffort = effort.reasoningEffort
                            } label: {
                                Text(effort.reasoningEffort)
                                    .font(LitterFont.monospaced(.caption2, weight: .medium))
                                    .foregroundColor(effort.reasoningEffort == appState.reasoningEffort ? .black : .white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort == appState.reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
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
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState

    private var models: [CodexModel] {
        serverManager.activeConnection?.models ?? []
    }

    private var currentModel: CodexModel? {
        models.first { $0.id == appState.selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(models) { model in
                Button {
                    appState.selectedModel = model.id
                    appState.reasoningEffort = model.defaultReasoningEffort
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(model.displayName)
                                    .font(LitterFont.monospaced(.footnote))
                                    .foregroundColor(.white)
                                if model.isDefault {
                                    Text("default")
                                        .font(LitterFont.monospaced(.caption2, weight: .medium))
                                        .foregroundColor(LitterTheme.accent)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(LitterTheme.accent.opacity(0.15))
                                        .clipShape(Capsule())
                                }
                            }
                            Text(model.description)
                                .font(LitterFont.monospaced(.caption2))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        Spacer()
                        if model.id == appState.selectedModel {
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
                                appState.reasoningEffort = effort.reasoningEffort
                            } label: {
                                Text(effort.reasoningEffort)
                                    .font(LitterFont.monospaced(.caption2, weight: .medium))
                                    .foregroundColor(effort.reasoningEffort == appState.reasoningEffort ? .black : .white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(effort.reasoningEffort == appState.reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
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
    LitterPreviewScene {
        HeaderView()
    }
}
#endif
