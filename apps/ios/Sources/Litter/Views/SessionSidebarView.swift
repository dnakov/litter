import SwiftUI
import Inject

struct SessionSidebarView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var isLoading = true
    @State private var resumingKey: ThreadKey?
    @State private var showSettings = false
    @State private var showDirectoryPicker = false
    @State private var selectedServerId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            newSessionButton
            Divider().background(Color(hex: "#1E1E1E"))
            serversRow
            Divider().background(Color(hex: "#1E1E1E"))

            if isLoading {
                Spacer()
                ProgressView().tint(LitterTheme.accent).frame(maxWidth: .infinity)
                Spacer()
            } else if serverManager.sortedThreads.isEmpty {
                Spacer()
                Text("No sessions yet")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                sessionList
            }

            Divider().background(Color(hex: "#1E1E1E"))
            settingsRow
        }
        .background(.ultraThinMaterial)
        .enableInjection()
        .task { await loadSessions() }
        .onChange(of: serverManager.hasAnyConnection) { _, connected in
            if connected { Task { await loadSessions() } }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(serverManager)
        }
        .sheet(isPresented: $showDirectoryPicker) {
            NavigationStack {
                DirectoryPickerView(
                    serverId: selectedServerId ?? connectedServerIds.first ?? "",
                    onDirectorySelected: { cwd in
                        showDirectoryPicker = false
                        let serverId = selectedServerId ?? connectedServerIds.first ?? ""
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    }
                )
                .environmentObject(serverManager)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { showDirectoryPicker = false }
                            .foregroundColor(LitterTheme.accent)
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
    }

    private var connectedServerIds: [String] {
        serverManager.connections.values.filter { $0.isConnected }.map(\.id)
    }

    private var settingsRow: some View {
        Button { showSettings = true } label: {
            HStack(spacing: 10) {
                Image(systemName: "gear")
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(width: 20)
                Text("Settings")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(LitterTheme.textSecondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
    }

    private var newSessionButton: some View {
        Button {
            let ids = connectedServerIds
            if ids.count == 1 {
                selectedServerId = ids.first
                showDirectoryPicker = true
            } else if ids.count > 1 {
                // Default to most recent server used
                selectedServerId = serverManager.activeThreadKey?.serverId ?? ids.first
                showDirectoryPicker = true
            } else {
                appState.showServerPicker = true
            }
        } label: {
            HStack {
                Image(systemName: "plus")
                    .font(.system(.subheadline, weight: .medium))
                Text("New Session")
                    .font(.system(.subheadline, design: .monospaced))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .modifier(GlassRectModifier(cornerRadius: 8, tint: LitterTheme.accent))
        }
        .padding(16)
    }

    private var serversRow: some View {
        HStack(spacing: 10) {
            let connected = serverManager.connections.values.filter { $0.isConnected }
            if connected.isEmpty {
                Image(systemName: "xmark.circle")
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(width: 20)
                Text("Not connected")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
                Spacer()
                Button("Connect") {
                    withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
                    appState.showServerPicker = true
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
            } else {
                Image(systemName: "server.rack")
                    .foregroundColor(LitterTheme.accent)
                    .frame(width: 20)
                Text("\(connected.count) server\(connected.count == 1 ? "" : "s")")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                Spacer()
                Button("Add") {
                    withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
                    appState.showServerPicker = true
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(serverManager.sortedThreads) { thread in
                    Button {
                        Task { await resumeSession(thread) }
                    } label: {
                        sessionRow(thread)
                    }
                    .disabled(resumingKey != nil)
                    Divider().background(Color(hex: "#1E1E1E")).padding(.leading, 16)
                }
            }
        }
    }

    private func sessionRow(_ thread: ThreadState) -> some View {
        HStack(spacing: 8) {
            if thread.hasTurnActive {
                PulsingDot()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(thread.preview.isEmpty ? "Untitled session" : thread.preview)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 6) {
                    Text(relativeDate(thread.updatedAt))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(LitterTheme.textSecondary)
                    HStack(spacing: 3) {
                        Image(systemName: serverIconName(for: thread.serverSource))
                            .font(.system(.caption2))
                        Text(thread.serverName)
                            .font(.system(.caption2, design: .monospaced))
                    }
                    .foregroundColor(LitterTheme.accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(LitterTheme.accent.opacity(0.12))
                    .cornerRadius(4)
                    Text((thread.cwd as NSString).lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(LitterTheme.textMuted)
                }
            }
            Spacer(minLength: 0)
            if resumingKey == thread.key {
                ProgressView()
                    .controlSize(.small)
                    .tint(LitterTheme.accent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private func loadSessions() async {
        guard serverManager.hasAnyConnection else {
            isLoading = false
            return
        }
        isLoading = true
        await serverManager.refreshAllSessions()
        isLoading = false
    }

    private func resumeSession(_ thread: ThreadState) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        await serverManager.viewThread(thread.key)
        resumingKey = nil
        withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
    }

    private func startNewSession(serverId: String, cwd: String) async {
        workDir = cwd
        appState.currentCwd = cwd
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        _ = await serverManager.startThread(serverId: serverId, cwd: cwd, model: model)
        withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

struct PulsingDot: View {
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(LitterTheme.accent)
            .frame(width: 8, height: 8)
            .scaleEffect(pulse ? 1.3 : 1.0)
            .opacity(pulse ? 0.6 : 1.0)
            .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulse)
            .onAppear { pulse = true }
    }
}
