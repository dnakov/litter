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
    @State private var sessionSearchQuery = ""

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
            } else if allThreads.isEmpty {
                Spacer()
                Text("No sessions yet")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                sessionSearchBar
                Divider().background(Color(hex: "#1E1E1E"))
                if filteredThreads.isEmpty {
                    Spacer()
                    Text("No matches for \"\(trimmedSessionSearchQuery)\"")
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    sessionList
                }
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
        .onChange(of: appState.sidebarOpen) { _, isOpen in
            if !isOpen {
                sessionSearchQuery = ""
            }
        }
        .onChange(of: connectedServerIds) { _, _ in
            guard showDirectoryPicker else { return }
            guard let fallbackServerId = defaultNewSessionServerId(preferredServerId: selectedServerId) else {
                showDirectoryPicker = false
                appState.showServerPicker = true
                return
            }
            if selectedServerId != fallbackServerId {
                selectedServerId = fallbackServerId
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(serverManager)
        }
        .sheet(isPresented: $showDirectoryPicker) {
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { selectedServerId = $0 }
                    ),
                    onServerChanged: { selectedServerId = $0 },
                    onDirectorySelected: { serverId, cwd in
                        showDirectoryPicker = false
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
        connectedServerOptions.map(\.id)
    }

    private var allThreads: [ThreadState] {
        serverManager.sortedThreads
    }

    private var trimmedSessionSearchQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredThreads: [ThreadState] {
        let query = trimmedSessionSearchQuery
        guard !query.isEmpty else { return allThreads }
        return allThreads.filter { threadMatchesSessionSearch($0, query: query) }
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        serverManager.connections.values
            .filter { $0.isConnected }
            .sorted {
                $0.server.name.localizedCaseInsensitiveCompare($1.server.name) == .orderedAscending
            }
            .map {
                DirectoryPickerServerOption(
                    id: $0.id,
                    name: $0.server.name,
                    sourceLabel: $0.server.source.rawString
                )
            }
    }

    private func defaultNewSessionServerId(preferredServerId: String? = nil) -> String? {
        let ids = connectedServerIds
        if ids.isEmpty { return nil }
        if let preferredServerId, ids.contains(preferredServerId) {
            return preferredServerId
        }
        if let activeServerId = serverManager.activeThreadKey?.serverId, ids.contains(activeServerId) {
            return activeServerId
        }
        if ids.count == 1 {
            return ids.first
        }
        return ids.first
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
            if let defaultServerId = defaultNewSessionServerId() {
                selectedServerId = defaultServerId
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

    private var sessionSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(LitterTheme.textMuted)
                .font(.system(.caption, design: .monospaced))

            TextField("Search sessions", text: $sessionSearchQuery)
                .font(.system(.footnote, design: .monospaced))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !sessionSearchQuery.isEmpty {
                Button {
                    sessionSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(LitterTheme.textMuted)
                        .font(.system(size: 14))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(LitterTheme.surface.opacity(0.55))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
        )
        .cornerRadius(8)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var sessionList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filteredThreads) { thread in
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

    private func threadMatchesSessionSearch(_ thread: ThreadState, query: String) -> Bool {
        thread.preview.localizedCaseInsensitiveContains(query) ||
            thread.cwd.localizedCaseInsensitiveContains(query) ||
            thread.serverName.localizedCaseInsensitiveContains(query)
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
        await serverManager.viewThread(
            thread.key,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        resumingKey = nil
        withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
    }

    private func startNewSession(serverId: String, cwd: String) async {
        workDir = cwd
        appState.currentCwd = cwd
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        _ = await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
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
