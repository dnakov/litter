import Foundation
import SwiftUI
import UIKit
import os
import Observation

struct DirectoryPickerServerOption: Identifiable, Hashable {
    let id: String
    let name: String
    let sourceLabel: String
    let backendKind: SavedServerBackendKind
    let backendLabel: String
    let subtitle: String
    let statusLabel: String
    let lastUsedDirectoryHint: String?
    let defaultModelLabel: String?
    let modelCatalogCountLabel: String
    let knownDirectories: [String]
    let canBrowseDirectories: Bool

    var isOpenCode: Bool {
        backendKind == .openCode
    }
}

private struct DirectoryPathBreadcrumb: Identifiable {
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

private func isDisconnectedClientError(_ error: Error) -> Bool {
    switch error {
    case let ClientError.Transport(message):
        return message.localizedCaseInsensitiveContains("disconnected")
    case let ClientError.Rpc(message):
        return message.localizedCaseInsensitiveContains("transport error") &&
            message.localizedCaseInsensitiveContains("disconnected")
    default:
        return false
    }
}

@MainActor
@Observable
private final class DirectoryPickerSheetModel {
    var currentPath = ""
    var allEntries: [String] = []
    var recentEntries: [RecentDirectoryEntry] = []
    var knownDirectories: [String] = []
    var isLoading = true
    var errorMessage: String?
    var showHiddenDirectories = false
    var searchQuery = ""

    @ObservationIgnored private var lastLoadedServerId = ""

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    var trimmedSearchQuery: String {
        searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var canNavigateUp: Bool {
        !currentPath.isEmpty && !RemotePath.parse(path: currentPath).isRoot()
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

    func pathSegments() -> [DirectoryPathBreadcrumb] {
        RemotePath.parse(path: currentPath).segments().map {
            DirectoryPathBreadcrumb(id: $0.fullPath, label: $0.label, path: $0.fullPath)
        }
    }

    func relativeDate(for date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    func handleServerSelectionChanged(_ server: DirectoryPickerServerOption) {
        let serverId = server.id
        if lastLoadedServerId != serverId {
            searchQuery = ""
            lastLoadedServerId = serverId
        }
        refreshKnownDirectories(server: server)
        refreshRecentEntries(serverId: serverId)
    }

    func loadInitialPath(
        selectedServer: DirectoryPickerServerOption,
        appModel: AppModel,
        isLocalServer: Bool
    ) async {
        let selectedServerId = selectedServer.id
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
        refreshKnownDirectories(server: selectedServer)
        refreshRecentEntries(serverId: targetServerId)

        if selectedServer.isOpenCode {
            currentPath = recentEntries.first?.path ?? knownDirectories.first ?? selectedServer.lastUsedDirectoryHint ?? ""
            isLoading = false
            return
        }

        let home = await resolveHome(for: targetServerId, appModel: appModel, isLocalServer: isLocalServer)
        guard targetServerId == selectedServerId else { return }
        currentPath = home
        await listDirectory(for: targetServerId, path: home, appModel: appModel, isLocalServer: isLocalServer)
    }

    func listDirectory(
        for serverId: String,
        path: String,
        appModel: AppModel,
        isLocalServer: Bool
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

        guard appModel.snapshot?.servers.first(where: { $0.serverId == serverId })?.canBrowseDirectories == true else { return }

        let normalizedPath = path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : path
        isLoading = true
        errorMessage = nil

        if isLocalServer {
            await listLocalDirectory(normalizedPath, serverId: serverId)
        } else {
            await listRemoteDirectory(normalizedPath, serverId: serverId, appModel: appModel)
        }

        if serverId == lastLoadedServerId {
            isLoading = false
        }
    }

    private func listLocalDirectory(_ path: String, serverId: String) async {
        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: path)
            guard serverId == lastLoadedServerId else { return }
            var dirs: [String] = []
            for name in contents {
                let fullPath = (path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), isDir.boolValue {
                    dirs.append(name)
                }
            }
            allEntries = dirs.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            withAnimation(.easeInOut(duration: 0.2)) {
                currentPath = path
            }
        } catch {
            guard serverId == lastLoadedServerId else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func listRemoteDirectory(_ path: String, serverId: String, appModel: AppModel) async {
        do {
            let result = try await appModel.client.listRemoteDirectory(serverId: serverId, path: path)
            guard serverId == lastLoadedServerId else { return }
            allEntries = result.directories
            withAnimation(.easeInOut(duration: 0.2)) {
                currentPath = result.path
            }
        } catch {
            guard serverId == lastLoadedServerId else { return }
            errorMessage = isDisconnectedClientError(error) ?
                DirectoryPickerStrings.serverNotConnected :
                error.localizedDescription
        }
    }

    func navigateInto(
        _ name: String,
        selectedServerId: String,
        appModel: AppModel,
        isLocalServer: Bool
    ) async {
        let nextPath = RemotePath.parse(path: currentPath).join(name: name).asString()
        await listDirectory(for: selectedServerId, path: nextPath, appModel: appModel, isLocalServer: isLocalServer)
    }

    func navigateUp(
        selectedServerId: String,
        appModel: AppModel,
        isLocalServer: Bool
    ) async {
        let nextPath = RemotePath.parse(path: currentPath).parent().asString()
        await listDirectory(for: selectedServerId, path: nextPath, appModel: appModel, isLocalServer: isLocalServer)
    }

    func navigateToPath(
        _ path: String,
        selectedServerId: String,
        appModel: AppModel,
        isLocalServer: Bool
    ) async {
        await listDirectory(for: selectedServerId, path: path, appModel: appModel, isLocalServer: isLocalServer)
    }

    func removeRecentEntry(_ entry: RecentDirectoryEntry, selectedServerId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            recentEntries = RecentDirectoryStore.shared.remove(path: entry.path, for: selectedServerId, limit: 3)
        }
    }

    func clearRecentEntries(selectedServerId: String) {
        withAnimation(.easeInOut(duration: 0.2)) {
            recentEntries = RecentDirectoryStore.shared.clear(for: selectedServerId)
        }
    }

    private func refreshRecentEntries(serverId: String) {
        recentEntries = RecentDirectoryStore.shared.recentDirectories(for: serverId, limit: 3)
    }

    private func refreshKnownDirectories(server: DirectoryPickerServerOption) {
        knownDirectories = SavedServerStore.server(id: server.id)?.openCodeKnownDirectories ?? server.knownDirectories
    }

    private func resolveHome(
        for serverId: String,
        appModel: AppModel,
        isLocalServer: Bool
    ) async -> String {
        guard appModel.snapshot?.servers.first(where: { $0.serverId == serverId })?.canBrowseDirectories == true else {
            return "/"
        }
        if isLocalServer {
            return NSHomeDirectory()
        }
        do {
            return try await appModel.client.resolveRemoteHome(serverId: serverId)
        } catch {
            if isDisconnectedClientError(error) {
                errorMessage = DirectoryPickerStrings.serverNotConnected
            }
            return "/"
        }
    }

}

struct DirectoryPickerView: View {
    let servers: [DirectoryPickerServerOption]
    @Binding var selectedServerId: String
    var onServerChanged: ((String) -> Void)?
    var onDirectorySelected: ((String, String) -> Void)?
    var onDismissRequested: (() -> Void)?

    @Environment(AppModel.self) private var appModel
    @State private var model = DirectoryPickerSheetModel()
    @State private var showClearRecentsConfirmation = false
    @State private var newScopeDraft = ""
    @State private var editingScope: String?
    @State private var editingScopeDraft = ""

    private var selectedServerOption: DirectoryPickerServerOption? {
        servers.first { $0.id == selectedServerId }
    }

    private var selectedServerSnapshot: AppServerSnapshot? {
        appModel.snapshot?.servers.first(where: { $0.serverId == selectedServerId })
    }

    private var selectedServerIsLocal: Bool {
        selectedServerSnapshot?.isLocal ?? false
    }

    private var canSelectPath: Bool {
        !model.currentPath.isEmpty && selectedServerOption != nil
    }

    private var showRecentDirectories: Bool {
        model.trimmedSearchQuery.isEmpty && !model.recentEntries.isEmpty
    }

    private var mostRecentEntry: RecentDirectoryEntry? {
        model.recentEntries.first
    }

    private var visibleKnownDirectories: [String] {
        let query = model.trimmedSearchQuery
        guard !query.isEmpty else { return model.knownDirectories }
        return model.knownDirectories.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { model.searchQuery },
            set: { model.searchQuery = $0 }
        )
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
        .navigationTitle(selectedServerOption?.isOpenCode == true ? "Pick Workspace" : DirectoryPickerStrings.title)
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled((selectedServerOption?.canBrowseDirectories == true) && model.canNavigateUp)
        .task(id: selectedServerId) {
            guard let selectedServerOption else { return }
            onServerChanged?(selectedServerId)
            model.handleServerSelectionChanged(selectedServerOption)
            await model.loadInitialPath(
                selectedServer: selectedServerOption,
                appModel: appModel,
                isLocalServer: selectedServerIsLocal
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
        .alert("Edit Directory Scope", isPresented: Binding(
            get: { editingScope != nil },
            set: { if !$0 { editingScope = nil; editingScopeDraft = "" } }
        )) {
            TextField("Directory", text: $editingScopeDraft)
            Button("Save") {
                guard let selectedServerOption, let editingScope else { return }
                SavedServerStore.replaceOpenCodeDirectory(
                    serverId: selectedServerOption.id,
                    previousDirectory: editingScope,
                    nextDirectory: editingScopeDraft
                )
                model.handleServerSelectionChanged(selectedServerOption)
                if model.currentPath == editingScope {
                    model.currentPath = editingScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                self.editingScope = nil
                editingScopeDraft = ""
            }
            Button("Cancel", role: .cancel) {
                editingScope = nil
                editingScopeDraft = ""
            }
        } message: {
            Text("Update the saved scope for this OpenCode server.")
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text(
                    DirectoryPickerStrings.connectedServer(
                        selectedServerOption.map { "\($0.name) • \($0.backendLabel)" } ??
                            DirectoryPickerStrings.noServerSelected
                    )
                )
                .litterFont(.caption)
                .foregroundColor(selectedServerOption == nil ? LitterTheme.textMuted : LitterTheme.textSecondary)
                .lineLimit(1)

                Spacer()

                if !servers.isEmpty {
                    Menu(DirectoryPickerStrings.changeServer) {
                        ForEach(servers) { server in
                            Button("\(server.name) • \(server.backendLabel)") {
                                selectedServerId = server.id
                            }
                        }
                    }
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.accent)
                }

                Button {
                    model.showHiddenDirectories.toggle()
                } label: {
                    Image(systemName: model.showHiddenDirectories ? "eye" : "eye.slash")
                        .foregroundColor(model.showHiddenDirectories ? LitterTheme.accent : LitterTheme.textSecondary)
                }
                .disabled(selectedServerOption?.canBrowseDirectories != true)
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
                    selectedServerOption?.isOpenCode == true ? "Search saved scopes" : DirectoryPickerStrings.searchFolders,
                    text: searchQueryBinding
                )
                .litterFont(.caption)
                .foregroundColor(LitterTheme.textPrimary)
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

            if let selectedServerOption {
                Text(selectedServerOption.subtitle)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)

                if selectedServerOption.canBrowseDirectories {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            Button {
                                Task {
                                    await model.navigateUp(
                                        selectedServerId: selectedServerId,
                                        appModel: appModel,
                                        isLocalServer: selectedServerIsLocal
                                    )
                                }
                            } label: {
                                Label(DirectoryPickerStrings.upOneLevel, systemImage: "arrow.up.backward")
                                    .litterFont(.caption)
                            }
                            .disabled(!model.canNavigateUp)

                            ForEach(model.pathSegments()) { segment in
                                Button {
                                    Task {
                                        await model.navigateToPath(
                                            segment.path,
                                            selectedServerId: selectedServerId,
                                            appModel: appModel,
                                            isLocalServer: selectedServerIsLocal
                                        )
                                    }
                                } label: {
                                    Text(segment.label)
                                        .litterFont(.caption)
                                        .foregroundColor(segment.path == model.currentPath ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
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
                } else if selectedServerOption.isOpenCode {
                    HStack(spacing: 8) {
                        TextField("Add directory scope", text: $newScopeDraft)
                            .litterFont(.caption)
                            .foregroundColor(LitterTheme.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled(true)

                        Button("Save") {
                            let nextDirectory = newScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !nextDirectory.isEmpty else { return }
                            SavedServerStore.appendOpenCodeDirectory(serverId: selectedServerOption.id, directory: nextDirectory)
                            model.handleServerSelectionChanged(selectedServerOption)
                            if model.currentPath.isEmpty {
                                model.currentPath = nextDirectory
                            }
                            newScopeDraft = ""
                        }
                        .disabled(newScopeDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.accent)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(LitterTheme.surface.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(LitterTheme.border.opacity(0.85), lineWidth: 1)
                    )
                    .cornerRadius(8)
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
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.danger)
                Text(err)
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                HStack(spacing: 12) {
                    Button(DirectoryPickerStrings.retry) {
                        Task {
                            await model.listDirectory(
                                for: selectedServerId,
                                path: model.currentPath,
                                appModel: appModel,
                                isLocalServer: selectedServerIsLocal
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
        } else if selectedServerOption?.isOpenCode == true {
            openCodeDirectoryList
        } else {
            directoryList
        }
    }

    private var openCodeDirectoryList: some View {
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
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                    .lineLimit(1)
                                Text(recent.path)
                                    .litterFont(.caption2)
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
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(recent.path)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(model.relativeDate(for: recent.lastUsedAt))
                                    .litterFont(.caption2)
                                    .foregroundColor(LitterTheme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                } header: {
                    Text("Recent Workspaces")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textSecondary)
                }
            }

            Section {
                if visibleKnownDirectories.isEmpty {
                    Text("Add at least one directory scope for this OpenCode server.")
                        .litterFont(.caption)
                        .foregroundColor(LitterTheme.textMuted)
                } else {
                    ForEach(visibleKnownDirectories, id: \.self) { directory in
                        Button {
                            model.currentPath = directory
                            emitSuccessHaptic()
                            withAnimation(.easeInOut(duration: 0.16)) {
                                onDirectorySelected?(selectedServerId, directory)
                            }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "folder.fill")
                                    .foregroundColor(LitterTheme.accent)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((directory as NSString).lastPathComponent)
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(directory)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                SavedServerStore.removeOpenCodeDirectory(serverId: selectedServerId, directory: directory)
                                if model.currentPath == directory {
                                    model.currentPath = ""
                                }
                                if let selectedServerOption {
                                    model.handleServerSelectionChanged(selectedServerOption)
                                }
                            } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: false) {
                            Button {
                                editingScope = directory
                                editingScopeDraft = directory
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(LitterTheme.accent)
                        }
                        .listRowBackground(LitterTheme.surface.opacity(0.6))
                    }
                }
            } header: {
                Text("Saved Directory Scopes")
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
            } footer: {
                Text("OpenCode sessions stay bound to one saved directory scope.")
                    .litterFont(.caption2)
                    .foregroundColor(LitterTheme.textMuted)
            }
        }
        .scrollContentBackground(.hidden)
        .animation(.easeInOut(duration: 0.2), value: model.knownDirectories)
        .accessibilityIdentifier("directoryPicker.list")
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
                                    .litterFont(.subheadline)
                                    .foregroundColor(LitterTheme.textPrimary)
                                    .lineLimit(1)
                                Text(recent.path)
                                    .litterFont(.caption2)
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
                                        .litterFont(.subheadline)
                                        .foregroundColor(LitterTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(recent.path)
                                        .litterFont(.caption2)
                                        .foregroundColor(LitterTheme.textMuted)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(model.relativeDate(for: recent.lastUsedAt))
                                    .litterFont(.caption2)
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
                            .litterFont(.caption)
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
                        .litterFont(.caption2)
                        .foregroundColor(LitterTheme.textMuted)
                }
            }

            let visibleEntries = model.visibleEntries()
            if visibleEntries.isEmpty {
                Text(model.emptyMessage())
                    .litterFont(.caption)
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
                                appModel: appModel,
                                isLocalServer: selectedServerIsLocal
                            )
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundColor(LitterTheme.accent)
                                .frame(width: 20)
                            Text(entry)
                                .litterFont(.subheadline)
                                .foregroundColor(LitterTheme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(LitterTheme.textMuted)
                                .litterFont(.caption)
                        }
                    }
                    .listRowBackground(LitterTheme.surface.opacity(0.6))
                }
            }
        }
        .scrollContentBackground(.hidden)
        .animation(.easeInOut(duration: 0.2), value: model.recentEntries)
        .accessibilityIdentifier("directoryPicker.list")
    }

    private var bottomActionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.currentPath.isEmpty {
                Text(model.currentPath)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if !canSelectPath {
                Text(selectedServerOption?.isOpenCode == true
                    ? "Choose a saved directory scope to start a session."
                    : DirectoryPickerStrings.chooseFolderHelper)
                    .litterFont(.caption)
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(spacing: 10) {
                Button(DirectoryPickerStrings.cancel) {
                    onDismissRequested?()
                }
                .buttonStyle(.plain)
                .litterFont(.subheadline)
                .foregroundColor(LitterTheme.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(LitterTheme.surface.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(LitterTheme.border.opacity(0.75), lineWidth: 1)
                )
                .cornerRadius(8)

                Button(selectedServerOption?.isOpenCode == true ? "Start Session" : DirectoryPickerStrings.selectFolder) {
                    emitSuccessHaptic()
                    withAnimation(.easeInOut(duration: 0.16)) {
                        onDirectorySelected?(selectedServerId, model.currentPath)
                    }
                }
                .accessibilityIdentifier("directoryPicker.selectFolderButton")
                .disabled(!canSelectPath)
                .buttonStyle(.plain)
                .litterFont(.subheadline)
                .foregroundColor(canSelectPath ? LitterTheme.textOnAccent : LitterTheme.textMuted)
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

#if DEBUG
#Preview("Directory Picker") {
    NavigationStack {
        DirectoryPickerView(
            servers: [
                DirectoryPickerServerOption(
                    id: "preview",
                    name: "Preview Server",
                    sourceLabel: "remote",
                    backendKind: .codex,
                    backendLabel: "Codex",
                    subtitle: "127.0.0.1:8390 • remote",
                    statusLabel: "Connected",
                    lastUsedDirectoryHint: "/tmp/litter",
                    defaultModelLabel: "gpt-5.4",
                    modelCatalogCountLabel: "12 models",
                    knownDirectories: [],
                    canBrowseDirectories: true
                )
            ],
            selectedServerId: .constant("preview"),
            onDismissRequested: {}
        )
        .environment(LitterPreviewData.makeDiscoveryAppModel())
    }
}
#endif
