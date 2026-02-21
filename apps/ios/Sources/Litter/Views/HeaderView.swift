import SwiftUI
import Inject

struct HeaderView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showModelSelector = false

    private var activeConn: ServerConnection? {
        serverManager.activeConnection
    }

    var body: some View {
        HStack(spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) {
                    appState.sidebarOpen.toggle()
                }
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(.title3, weight: .medium))
                    .foregroundColor(Color(hex: "#999999"))
            }

            Button { showModelSelector = true } label: {
                HStack(spacing: 6) {
                    if serverManager.activeThreadKey != nil, !shortModelName.isEmpty {
                        Text(shortModelName)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundColor(.white)
                    } else {
                        Text("litter")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundColor(.white)
                        if !shortModelName.isEmpty {
                            Text(shortModelName)
                                .font(.system(.title3))
                                .foregroundColor(Color(hex: "#666666"))
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(Color(hex: "#666666"))
                }
            }

            Spacer()

            statusDot
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .onChange(of: serverManager.activeThreadKey) { _, _ in
            Task { await loadModelsIfNeeded() }
        }
        .task {
            await loadModelsIfNeeded()
        }
        .enableInjection()
        .sheet(isPresented: $showModelSelector) {
            ModelSelectorView()
                .environmentObject(serverManager)
                .environmentObject(appState)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    private var shortModelName: String {
        if appState.selectedModel.isEmpty { return "" }
        return appState.selectedModel
            .replacingOccurrences(of: "gpt-", with: "")
            .replacingOccurrences(of: "-codex", with: "")
    }

    private func loadModelsIfNeeded() async {
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

    @ViewBuilder
    private var statusDot: some View {
        let status = serverManager.activeThread?.status
        switch status {
        case .idle, .none:
            if serverManager.hasAnyConnection {
                Circle().fill(LitterTheme.accent).frame(width: 8, height: 8)
            } else {
                Circle().fill(LitterTheme.textMuted).frame(width: 8, height: 8)
            }
        case .connecting:
            Circle().fill(Color.yellow).frame(width: 8, height: 8)
        case .ready:
            Circle().fill(LitterTheme.accent).frame(width: 8, height: 8)
        case .thinking:
            ProgressView()
                .scaleEffect(0.6)
                .tint(LitterTheme.accent)
        case .error:
            Circle().fill(Color.red).frame(width: 8, height: 8)
        }
    }
}

struct ModelSelectorView: View {
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var loadError: String?

    private var models: [CodexModel] {
        serverManager.activeConnection?.models ?? []
    }

    private var currentModel: CodexModel? {
        models.first { $0.id == appState.selectedModel }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Model")
                .font(.system(.subheadline, weight: .semibold))
                .foregroundColor(.white)
                .padding(.top, 20)
                .padding(.bottom, 16)

            if models.isEmpty {
                Spacer()
                if let err = loadError {
                    Text(err)
                        .font(.system(.footnote))
                        .foregroundColor(LitterTheme.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                    Button("Retry") {
                        loadError = nil
                        Task { await loadModels() }
                    }
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(LitterTheme.accent)
                } else {
                    ProgressView().tint(LitterTheme.accent)
                }
                Spacer()
            } else {
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
                                                .font(.system(.subheadline))
                                                .foregroundColor(.white)
                                            if model.isDefault {
                                                Text("default")
                                                    .font(.system(.caption2, weight: .medium))
                                                    .foregroundColor(LitterTheme.accent)
                                                    .padding(.horizontal, 6)
                                                    .padding(.vertical, 2)
                                                    .background(LitterTheme.accent.opacity(0.15))
                                                    .clipShape(Capsule())
                                            }
                                        }
                                        Text(model.description)
                                            .font(.system(.caption))
                                            .foregroundColor(LitterTheme.textSecondary)
                                    }
                                    Spacer()
                                    if model.id == appState.selectedModel {
                                        Image(systemName: "checkmark")
                                            .font(.system(.subheadline, weight: .medium))
                                            .foregroundColor(LitterTheme.accent)
                                    }
                                }
                                .padding(.horizontal, 20)
                                .padding(.vertical, 12)
                            }
                            Divider().background(Color(hex: "#1E1E1E")).padding(.leading, 20)
                        }

                        if let info = currentModel, !info.supportedReasoningEfforts.isEmpty {
                            Text("Reasoning")
                                .font(.system(.subheadline, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 20)
                                .padding(.top, 20)
                                .padding(.bottom, 12)

                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(info.supportedReasoningEfforts) { effort in
                                        Button {
                                            appState.reasoningEffort = effort.reasoningEffort
                                        } label: {
                                            Text(effort.reasoningEffort)
                                                .font(.system(.footnote, weight: .medium))
                                                .foregroundColor(effort.reasoningEffort == appState.reasoningEffort ? .black : .white)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 8)
                                                .background(effort.reasoningEffort == appState.reasoningEffort ? LitterTheme.accent : LitterTheme.surfaceLight)
                                                .clipShape(Capsule())
                                        }
                                    }
                                }
                                .padding(.horizontal, 20)
                            }
                        }
                    }
                }
            }

            Spacer()
        }
        .background(.ultraThinMaterial)
        .task {
            if models.isEmpty { await loadModels() }
        }
    }

    private func loadModels() async {
        guard let conn = serverManager.activeConnection, conn.isConnected else {
            loadError = "Not connected to a server"
            return
        }
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
        } catch {
            loadError = error.localizedDescription
        }
    }
}
