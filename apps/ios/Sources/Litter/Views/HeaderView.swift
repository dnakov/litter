import SwiftUI
import Inject

struct HeaderView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var showModelSelector = false
    @State private var isReloading = false

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
                    if serverManager.activeThreadKey != nil, !selectedModelName.isEmpty {
                        Text(selectedModelName)
                            .font(.system(.title3, weight: .semibold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                            .allowsTightening(true)
                    } else {
                        Text("litter")
                            .font(.system(.title3, weight: .semibold))
                            .foregroundColor(.white)
                        if !selectedModelName.isEmpty {
                            Text(selectedModelName)
                                .font(.system(.title3))
                                .foregroundColor(Color(hex: "#666666"))
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .allowsTightening(true)
                        }
                    }
                    Image(systemName: "chevron.right")
                        .font(.system(.caption, weight: .medium))
                        .foregroundColor(Color(hex: "#666666"))
                }
            }

            Spacer()

            reloadButton
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

    private var selectedModelName: String {
        appState.selectedModel
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

    private var reloadButton: some View {
        Button {
            Task {
                isReloading = true
                await serverManager.refreshAllSessions()
                await serverManager.syncActiveThreadFromServer()
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
                        .font(.system(.subheadline, weight: .semibold))
                        .foregroundColor(serverManager.hasAnyConnection ? LitterTheme.accent : LitterTheme.textMuted)
                }
            }
            .frame(width: 18, height: 18)
        }
        .disabled(isReloading || !serverManager.hasAnyConnection)
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
