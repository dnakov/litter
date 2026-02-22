import SwiftUI

struct DirectoryPickerServerOption: Identifiable, Hashable {
    let id: String
    let name: String
    let sourceLabel: String
}

struct DirectoryPickerView: View {
    let servers: [DirectoryPickerServerOption]
    @Binding var selectedServerId: String
    var onServerChanged: ((String) -> Void)?
    var onDirectorySelected: ((String, String) -> Void)?
    @EnvironmentObject var serverManager: ServerManager
    @State private var currentPath = ""
    @State private var allEntries: [String] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showHiddenDirectories = false
    @State private var searchQuery = ""

    private var selectedServerOption: DirectoryPickerServerOption? {
        servers.first { $0.id == selectedServerId }
    }

    private var conn: ServerConnection? {
        serverManager.connections[selectedServerId]
    }

    private var canSelectPath: Bool {
        !currentPath.isEmpty && conn?.isConnected == true && selectedServerOption != nil
    }

    private var visibleEntries: [String] {
        let hiddenFiltered = showHiddenDirectories ? allEntries : allEntries.filter { !$0.hasPrefix(".") }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return hiddenFiltered }
        return hiddenFiltered.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var emptyMessage: String {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty {
            return "No folders found"
        }
        return "No matches for \"\(query)\""
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                serverSelectorBar
                pathBar
                Divider().background(Color(hex: "#1E1E1E"))
                content
            }
        }
        .navigationTitle("Choose Directory")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showHiddenDirectories.toggle()
                } label: {
                    Image(systemName: showHiddenDirectories ? "eye" : "eye.slash")
                        .foregroundColor(showHiddenDirectories ? LitterTheme.accent : LitterTheme.textSecondary)
                }
                .accessibilityLabel(showHiddenDirectories ? "Hide Hidden Folders" : "Show Hidden Folders")
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Select") { onDirectorySelected?(selectedServerId, currentPath) }
                    .foregroundColor(LitterTheme.accent)
                    .disabled(!canSelectPath)
            }
        }
        .task(id: selectedServerId) { await loadInitialPath() }
        .onChange(of: selectedServerId) { _, value in
            onServerChanged?(value)
        }
        .onChange(of: servers.map(\.id)) { _, ids in
            if !ids.contains(selectedServerId), let fallback = ids.first {
                selectedServerId = fallback
            }
        }
    }

    private var serverSelectorBar: some View {
        HStack(spacing: 8) {
            Text("Server")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.textSecondary)
            Spacer()
            if servers.isEmpty {
                Text("No connected server")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
            } else {
                Picker("Server", selection: $selectedServerId) {
                    ForEach(servers) { server in
                        Text("\(server.name) • \(server.sourceLabel)")
                            .tag(server.id)
                    }
                }
                .pickerStyle(.menu)
                .tint(LitterTheme.accent)
                .font(.system(.caption, design: .monospaced))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var pathBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Text(currentPath.isEmpty ? "~" : currentPath)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(LitterTheme.accent)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView().tint(LitterTheme.accent).frame(maxHeight: .infinity)
        } else if let err = errorMessage {
            VStack(spacing: 12) {
                Text(err)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                Button("Retry") { Task { await loadInitialPath() } }
                    .foregroundColor(LitterTheme.accent)
            }
            .frame(maxHeight: .infinity)
        } else {
            directoryList
        }
    }

    private var directoryList: some View {
        List {
            if currentPath != "/" {
                Button {
                    Task { await navigateUp() }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "arrow.turn.up.left")
                            .foregroundColor(LitterTheme.textSecondary)
                            .frame(width: 20)
                        Text("..")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if visibleEntries.isEmpty {
                Text(emptyMessage)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(LitterTheme.textMuted)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            } else {
                ForEach(visibleEntries, id: \.self) { entry in
                    Button {
                        Task { await navigateInto(entry) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            Text(entry)
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundColor(.white)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(LitterTheme.textMuted)
                                .font(.caption)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .searchable(
            text: $searchQuery,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "Search folders"
        )
    }

    // MARK: - Actions

    private func loadInitialPath() async {
        let targetServerId = selectedServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetServerId.isEmpty else {
            isLoading = false
            allEntries = []
            errorMessage = "No server selected"
            currentPath = ""
            return
        }
        isLoading = true
        errorMessage = nil
        allEntries = []
        searchQuery = ""
        currentPath = ""

        let home = await resolveHome(for: targetServerId)
        guard targetServerId == selectedServerId else { return }
        currentPath = home
        await listDirectory(for: targetServerId, path: home)
    }

    private func resolveHome(for serverId: String) async -> String {
        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            return "/"
        }
        if connection.server.source == .local {
            return NSHomeDirectory()
        }
        do {
            let resp = try await connection.execCommand(
                ["/bin/sh", "-lc", "printf %s \"$HOME\""],
                cwd: "/tmp"
            )
            if resp.exitCode == 0 {
                let home = resp.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty { return home }
            }
        } catch {}
        return "/"
    }

    private func listDirectory(for serverId: String, path: String) async {
        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            if serverId == selectedServerId {
                isLoading = false
                allEntries = []
                errorMessage = "Selected server is not connected"
            }
            return
        }
        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : path
        isLoading = true
        errorMessage = nil
        do {
            let resp = try await connection.execCommand(
                ["/bin/ls", "-1ap", normalizedPath],
                cwd: normalizedPath
            )
            guard serverId == selectedServerId else { return }
            if resp.exitCode != 0 {
                errorMessage = resp.stderr.isEmpty ? "ls failed with code \(resp.exitCode)" : resp.stderr
                isLoading = false
                return
            }
            let lines = resp.stdout.split(separator: "\n").map(String.init)
            let dirs = lines.filter { $0.hasSuffix("/") && $0 != "./" && $0 != "../" }
            allEntries = dirs
                .map { String($0.dropLast()) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        } catch {
            guard serverId == selectedServerId else { return }
            errorMessage = error.localizedDescription
        }
        if serverId == selectedServerId {
            isLoading = false
        }
    }

    private func clearSearchIfNeeded() {
        if !searchQuery.isEmpty {
            searchQuery = ""
        }
    }

    private func navigateInto(_ name: String) async {
        clearSearchIfNeeded()
        let serverId = selectedServerId
        var nextPath = currentPath
        if nextPath.hasSuffix("/") {
            nextPath += name
        } else {
            nextPath += "/\(name)"
        }
        currentPath = nextPath
        await listDirectory(for: serverId, path: nextPath)
    }

    private func navigateUp() async {
        clearSearchIfNeeded()
        let serverId = selectedServerId
        var nextPath = (currentPath as NSString).deletingLastPathComponent
        if nextPath.isEmpty {
            nextPath = "/"
        }
        currentPath = nextPath
        await listDirectory(for: serverId, path: nextPath)
    }
}
