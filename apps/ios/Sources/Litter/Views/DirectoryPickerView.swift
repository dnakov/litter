import SwiftUI
import UIKit
import os

struct DirectoryPickerServerOption: Identifiable, Hashable {
    let id: String
    let name: String
    let sourceLabel: String
}

private struct DirectoryPathSegment: Identifiable {
    let id: String
    let label: String
    let path: String
}

private enum DirectoryPickerStrings {
    static let title = String(localized: "directory_picker_title")
    static let changeServer = String(localized: "directory_picker_change_server")
    static let searchFolders = String(localized: "directory_picker_search_folders")
    static let upOneLevel = String(localized: "directory_picker_up_one_level")
    static let loadError = String(localized: "directory_picker_load_error")
    static let retry = String(localized: "directory_picker_retry")
    static let recentDirectories = String(localized: "directory_picker_recent_directories")
    static let clearRecentDirectories = String(localized: "directory_picker_clear_recent_directories")
    static let recentFooter = String(localized: "directory_picker_recent_footer")
    static let noSubdirectories = String(localized: "directory_picker_no_subdirectories")
    static let chooseFolderHelper = String(localized: "directory_picker_choose_folder_helper")
    static let selectFolder = String(localized: "directory_picker_select_folder")
    static let cancel = String(localized: "directory_picker_cancel")
    static let clearRecentTitle = String(localized: "directory_picker_clear_recent_title")
    static let clearRecentMessage = String(localized: "directory_picker_clear_recent_message")
    static let clear = String(localized: "directory_picker_clear")
    static let noServerSelected = String(localized: "directory_picker_no_server_selected")
    static let serverNotConnected = String(localized: "directory_picker_server_not_connected")

    static func connectedServer(_ label: String) -> String {
        String.localizedStringWithFormat(String(localized: "directory_picker_connected_server"), label)
    }

    static func noMatches(_ query: String) -> String {
        String.localizedStringWithFormat(String(localized: "directory_picker_no_matches"), query)
    }

    static func continueIn(_ folder: String) -> String {
        String.localizedStringWithFormat(String(localized: "directory_picker_continue_in_folder"), folder)
    }

}

private let directoryPickerSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "DirectoryPicker"
)

@MainActor
private final class DirectoryPickerSheetModel: ObservableObject {
    @Published var currentPath = ""
    @Published var allEntries: [String] = []
    @Published var recentEntries: [RecentDirectoryEntry] = []
    @Published var isLoading = true
    @Published var errorMessage: String?
    @Published var showHiddenDirectories = false
    @Published var searchQuery = ""

    private var lastLoadedServerId = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canNavigateUp: Bool {
        currentPath != "/" && !currentPath.isEmpty
    }

    func visibleEntries() -> [String] {
        let hiddenFiltered = showHiddenDirectories ? allEntries : allEntries.filter { !$0.hasPrefix(".") }
        guard !trimmedSearchQuery.isEmpty else { return hiddenFiltered }
        return hiddenFiltered.filter { $0.localizedCaseInsensitiveContains(trimmedSearchQuery) }
    }

    func emptyMessage() -> String {
        if trimmedSearchQuery.isEmpty {
            return DirectoryPickerStrings.noSubdirectories
        }
        return DirectoryPickerStrings.noMatches(trimmedSearchQuery)
    }

    func pathSegments() -> [DirectoryPathSegment] {
        segments(for: currentPath)
    }

    func relativeDate(for date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func handleServerSelectionChanged(_ serverId: String) {
        if lastLoadedServerId != serverId {
            searchQuery = ""
            lastLoadedServerId = serverId
        }
        refreshRecentEntries(serverId: serverId)
    }

    func loadInitialPath(
        selectedServerId: String,
        serverManager: ServerManager
    ) async {
        let signpostID = OSSignpostID(log: directoryPickerSignpostLog)
        os_signpost(
            .begin,
            log: directoryPickerSignpostLog,
            name: "LoadInitialPath",
            signpostID: signpostID,
            "server=%{public}@",
            selectedServerId
        )
        defer {
            os_signpost(
                .end,
                log: directoryPickerSignpostLog,
                name: "LoadInitialPath",
                signpostID: signpostID
            )
        }

        let targetServerId = selectedServerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !targetServerId.isEmpty else {
            isLoading = false
            allEntries = []
            errorMessage = DirectoryPickerStrings.noServerSelected
            currentPath = ""
            return
        }

        isLoading = true
        errorMessage = nil
        allEntries = []
        currentPath = ""

        let home = await resolveHome(for: targetServerId, serverManager: serverManager)
        guard targetServerId == selectedServerId else { return }
        currentPath = home
        await listDirectory(for: targetServerId, path: home, serverManager: serverManager)
    }

    func listDirectory(
        for serverId: String,
        path: String,
        serverManager: ServerManager
    ) async {
        let signpostID = OSSignpostID(log: directoryPickerSignpostLog)
        os_signpost(
            .begin,
            log: directoryPickerSignpostLog,
            name: "ListDirectory",
            signpostID: signpostID,
            "server=%{public}@ path=%{public}@",
            serverId,
            path
        )
        defer {
            os_signpost(
                .end,
                log: directoryPickerSignpostLog,
                name: "ListDirectory",
                signpostID: signpostID
            )
        }

        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            if serverId == lastLoadedServerId {
                isLoading = false
                allEntries = []
                errorMessage = DirectoryPickerStrings.serverNotConnected
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
            guard serverId == lastLoadedServerId else { return }

            if resp.exitCode != 0 {
                errorMessage = resp.stderr.isEmpty ? "ls failed with code \(resp.exitCode)" : resp.stderr
                isLoading = false
                return
            }

            let lines = resp.stdout.split(separator: "\n").map(String.init)
            let directories = lines.filter { $0.hasSuffix("/") && $0 != "./" && $0 != "../" }
            allEntries =
                directories
                .map { String($0.dropLast()) }
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            withAnimation(.easeInOut(duration: 0.2)) {
                currentPath = normalizedPath
            }
        } catch {
            guard serverId == lastLoadedServerId else { return }
            errorMessage = error.localizedDescription
        }

        if serverId == lastLoadedServerId {
            isLoading = false
        }
    }

    func navigateInto(
        _ name: String,
        selectedServerId: String,
        serverManager: ServerManager
    ) async {
        var nextPath = currentPath
        if nextPath.hasSuffix("/") {
            nextPath += name
        } else {
            nextPath += "/\(name)"
        }
        await listDirectory(for: selectedServerId, path: nextPath, serverManager: serverManager)
    }

    func navigateUp(
        selectedServerId: String,
        serverManager: ServerManager
    ) async {
        var nextPath = (currentPath as NSString).deletingLastPathComponent
        if nextPath.isEmpty {
            nextPath = "/"
        }
        await listDirectory(for: selectedServerId, path: nextPath, serverManager: serverManager)
    }

    func navigateToPath(
        _ path: String,
        selectedServerId: String,
        serverManager: ServerManager
    ) async {
        await listDirectory(for: selectedServerId, path: path, serverManager: serverManager)
    }

    func removeRecentEntry(_ entry: RecentDirectoryEntry, selectedServerId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            recentEntries = RecentDirectoryStore.shared.remove(path: entry.path, for: selectedServerId)
        }
    }

    func clearRecentEntries(selectedServerId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            recentEntries = RecentDirectoryStore.shared.clear(for: selectedServerId)
        }
    }

    private func refreshRecentEntries(serverId: String) {
        recentEntries = RecentDirectoryStore.shared.recentDirectories(for: serverId)
    }

    private func resolveHome(
        for serverId: String,
        serverManager: ServerManager
    ) async -> String {
        guard let connection = serverManager.connections[serverId], connection.isConnected else {
            return "/"
        }
        if connection.server.source == .local {
            return NSHomeDirectory()
        }
        do {
            let response = try await connection.execCommand(
                ["/bin/sh", "-lc", "printf %s \"$HOME\""],
                cwd: "/tmp"
            )
            if response.exitCode == 0 {
                let home = response.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !home.isEmpty {
                    return home
                }
            }
        } catch {}
        return "/"
    }

    private func segments(for path: String) -> [DirectoryPathSegment] {
        let normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty || normalized == "/" {
            return [DirectoryPathSegment(id: "/", label: "/", path: "/")]
        }

        var output: [DirectoryPathSegment] = [DirectoryPathSegment(id: "/", label: "/", path: "/")]
        var runningPath = ""
        for component in normalized.split(separator: "/").map(String.init).filter({ !$0.isEmpty }) {
            runningPath = runningPath.isEmpty ? "/\(component)" : "\(runningPath)/\(component)"
            output.append(DirectoryPathSegment(id: runningPath, label: component, path: runningPath))
        }
        return output
    }
}

struct DirectoryPickerView: View {
    let servers: [DirectoryPickerServerOption]
    @Binding var selectedServerId: String
    var onServerChanged: ((String) -> Void)?
    var onDirectorySelected: ((String, String) -> Void)?
    var onDismissRequested: (() -> Void)?

    @EnvironmentObject var serverManager: ServerManager
    @StateObject private var model = DirectoryPickerSheetModel()
    @State private var showClearRecentsConfirmation = false

    private var selectedServerOption: DirectoryPickerServerOption? {
        servers.first { $0.id == selectedServerId }
    }

    private var conn: ServerConnection? {
        serverManager.connections[selectedServerId]
    }

    private var canSelectPath: Bool {
        !model.currentPath.isEmpty && conn?.isConnected == true && selectedServerOption != nil
    }

    private var showRecentDirectories: Bool {
        model.trimmedSearchQuery.isEmpty && !model.recentEntries.isEmpty
    }

    private var mostRecentEntry: RecentDirectoryEntry? {
        model.recentEntries.first
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 0) {
                controls
                Divider().background(LitterTheme.separator)
                content
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomActionBar
        }
        .navigationTitle(DirectoryPickerStrings.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .interactiveDismissDisabled(model.canNavigateUp)
        .task(id: selectedServerId) {
            onServerChanged?(selectedServerId)
            model.handleServerSelectionChanged(selectedServerId)
            await model.loadInitialPath(
                selectedServerId: selectedServerId,
                serverManager: serverManager
            )
        }
        .onChange(of: servers.map(\.id)) { _, ids in
            if !ids.contains(selectedServerId), let fallback = ids.first {
                selectedServerId = fallback
            }
        }
        .confirmationDialog(
            DirectoryPickerStrings.clearRecentTitle,
            isPresented: $showClearRecentsConfirmation,
            titleVisibility: .visible
        ) {
            Button(DirectoryPickerStrings.clear, role: .destructive) {
                model.clearRecentEntries(selectedServerId: selectedServerId)
            }
            Button(DirectoryPickerStrings.cancel, role: .cancel) {}
        } message: {
            Text(DirectoryPickerStrings.clearRecentMessage)
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(
                    DirectoryPickerStrings.connectedServer(
                        selectedServerOption.map { "\($0.name) • \($0.sourceLabel)" } ??
                            DirectoryPickerStrings.noServerSelected
                    )
                )
                .font(LitterFont.monospaced(.caption))
                .foregroundColor(selectedServerOption == nil ? LitterTheme.textMuted : LitterTheme.textSecondary)
                .lineLimit(1)

                Spacer()

                if !servers.isEmpty {
                    Menu(DirectoryPickerStrings.changeServer) {
                        ForEach(servers) { server in
                            Button("\(server.name) • \(server.sourceLabel)") {
                                selectedServerId = server.id
                            }
                        }
                    }
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.accent)
                }

                Button {
                    model.showHiddenDirectories.toggle()
                } label: {
                    Image(systemName: model.showHiddenDirectories ? "eye" : "eye.slash")
                        .foregroundColor(model.showHiddenDirectories ? LitterTheme.accent : LitterTheme.textSecondary)
                }
                .accessibilityLabel(
                    model.showHiddenDirectories ?
                        String(localized: "directory_picker_hide_hidden_folders") :
                        String(localized: "directory_picker_show_hidden_folders")
                )
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(LitterTheme.textMuted)
                TextField(
                    DirectoryPickerStrings.searchFolders,
                    text: $model.searchQuery
                )
                .font(LitterFont.monospaced(.caption))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

                if !model.searchQuery.isEmpty {
                    Button {
                        model.searchQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(LitterTheme.surface.opacity(0.65))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
            )
            .cornerRadius(8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button {
                        Task {
                            await model.navigateUp(
                                selectedServerId: selectedServerId,
                                serverManager: serverManager
                            )
                        }
                    } label: {
                        Label(DirectoryPickerStrings.upOneLevel, systemImage: "arrow.up.backward")
                            .font(LitterFont.monospaced(.caption))
                    }
                    .disabled(!model.canNavigateUp)

                    ForEach(model.pathSegments()) { segment in
                        Button {
                            Task {
                                await model.navigateToPath(
                                    segment.path,
                                    selectedServerId: selectedServerId,
                                    serverManager: serverManager
                                )
                            }
                        } label: {
                            Text(segment.label)
                                .font(LitterFont.monospaced(.caption))
                                .foregroundColor(segment.path == model.currentPath ? .black : LitterTheme.textSecondary)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(segment.path == model.currentPath ? LitterTheme.accent : LitterTheme.surface.opacity(0.65))
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            ProgressView().tint(LitterTheme.accent).frame(maxHeight: .infinity)
        } else if let err = model.errorMessage {
            VStack(spacing: 12) {
                Text(DirectoryPickerStrings.loadError)
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.danger)
                Text(err)
                    .font(LitterFont.monospaced(.caption2))
                    .foregroundColor(LitterTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                HStack(spacing: 12) {
                    Button(DirectoryPickerStrings.retry) {
                        Task {
                            await model.listDirectory(
                                for: selectedServerId,
                                path: model.currentPath,
                                serverManager: serverManager
                            )
                        }
                    }
                    .foregroundColor(LitterTheme.accent)

                    Button(DirectoryPickerStrings.changeServer) {
                        selectNextServer()
                    }
                    .foregroundColor(LitterTheme.accent)
                }
            }
            .frame(maxHeight: .infinity)
        } else {
            directoryList
        }
    }

    private var directoryList: some View {
        List {
            if let recent = mostRecentEntry {
                Section {
                    Button {
                        emitSuccessHaptic()
                        withAnimation(.easeInOut(duration: 0.16)) {
                            onDirectorySelected?(selectedServerId, recent.path)
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "play.fill")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(DirectoryPickerStrings.continueIn((recent.path as NSString).lastPathComponent))
                                    .font(LitterFont.monospaced(.subheadline))
                                    .foregroundColor(.white)
                                    .lineLimit(1)
                                Text(recent.path)
                                    .font(LitterFont.monospaced(.caption2))
                                    .foregroundColor(LitterTheme.textMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                        }
                    }
                }
                .listRowBackground(LitterTheme.surface.opacity(0.6))
            }

            if showRecentDirectories {
                Section {
                    ForEach(model.recentEntries) { recent in
                        Button {
                            emitSuccessHaptic()
                            withAnimation(.easeInOut(duration: 0.16)) {
                                onDirectorySelected?(selectedServerId, recent.path)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((recent.path as NSString).lastPathComponent)
                                        .font(LitterFont.monospaced(.subheadline))
                                        .foregroundColor(.white)
                                        .lineLimit(1)
                                    Text(recent.path)
                                        .font(LitterFont.monospaced(.caption2))
                                        .foregroundColor(LitterTheme.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(model.relativeDate(for: recent.lastUsedAt))
                                    .font(LitterFont.monospaced(.caption2))
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) {
                                model.removeRecentEntry(recent, selectedServerId: selectedServerId)
                            } label: {
                                Label(String(localized: "directory_picker_remove_recent"), systemImage: "trash")
                            }
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                } header: {
                    HStack {
                        Text(DirectoryPickerStrings.recentDirectories)
                            .font(LitterFont.monospaced(.caption))
                            .foregroundColor(LitterTheme.textSecondary)
                        Spacer()
                        Menu {
                            Button(DirectoryPickerStrings.clearRecentDirectories, role: .destructive) {
                                showClearRecentsConfirmation = true
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .foregroundColor(LitterTheme.textMuted)
                        }
                    }
                } footer: {
                    Text(DirectoryPickerStrings.recentFooter)
                        .font(LitterFont.monospaced(.caption2))
                        .foregroundColor(LitterTheme.textMuted)
                }
            }

            let visibleEntries = model.visibleEntries()
            if visibleEntries.isEmpty {
                Text(model.emptyMessage())
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.textMuted)
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
            } else {
                ForEach(visibleEntries, id: \.self) { entry in
                    Button {
                        emitSelectionHaptic()
                        Task {
                            await model.navigateInto(
                                entry,
                                selectedServerId: selectedServerId,
                                serverManager: serverManager
                            )
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            Text(entry)
                                .font(LitterFont.monospaced(.subheadline))
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
        .animation(.easeInOut(duration: 0.2), value: model.recentEntries)
    }

    private var bottomActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.currentPath.isEmpty {
                Text(model.currentPath)
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !canSelectPath {
                Text(DirectoryPickerStrings.chooseFolderHelper)
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button(DirectoryPickerStrings.cancel) {
                    onDismissRequested?()
                }
                .buttonStyle(.plain)
                .font(LitterFont.monospaced(.subheadline))
                .foregroundColor(LitterTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(LitterTheme.surface.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(LitterTheme.border.opacity(0.75), lineWidth: 1)
                )
                .cornerRadius(8)

                Button(DirectoryPickerStrings.selectFolder) {
                    emitSuccessHaptic()
                    withAnimation(.easeInOut(duration: 0.16)) {
                        onDirectorySelected?(selectedServerId, model.currentPath)
                    }
                }
                .disabled(!canSelectPath)
                .buttonStyle(.plain)
                .font(LitterFont.monospaced(.subheadline))
                .foregroundColor(canSelectPath ? .black : LitterTheme.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(canSelectPath ? LitterTheme.accent : LitterTheme.surface.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(canSelectPath ? LitterTheme.accent.opacity(0.8) : LitterTheme.border.opacity(0.75), lineWidth: 1)
                )
                .cornerRadius(8)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    private func selectNextServer() {
        guard !servers.isEmpty else { return }
        guard let currentIndex = servers.firstIndex(where: { $0.id == selectedServerId }) else {
            selectedServerId = servers[0].id
            return
        }
        let nextIndex = (currentIndex + 1) % servers.count
        selectedServerId = servers[nextIndex].id
    }

    private func emitSelectionHaptic() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func emitSuccessHaptic() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

#Preview("Directory Picker") {
    NavigationStack {
        DirectoryPickerView(
            servers: [],
            selectedServerId: .constant(""),
            onDismissRequested: {}
        )
        .environmentObject(ServerManager())
    }
    .preferredColorScheme(.dark)
}
