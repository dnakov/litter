import SwiftUI
import Inject
import os

private let sessionSidebarSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "SessionSidebar"
)

struct SessionSidebarView: View {
    @ObserveInjection var inject
    @EnvironmentObject var serverManager: ServerManager
    @EnvironmentObject var appState: AppState
    @State private var isLoading = true
    @State private var resumingKey: ThreadKey?
    @State private var showSettings = false
    @State private var directoryPickerSheet: DirectoryPickerSheetModel?
    @State private var sessionSearchQuery = ""
    @State private var debouncedSessionSearchQuery = ""
    @State private var isForkingActiveThread = false
    @State private var sessionActionErrorMessage: String?
    @State private var renamingThreadKey: ThreadKey?
    @State private var renameCurrentTitle = ""
    @State private var renameDraft = ""
    @State private var archiveTargetKey: ThreadKey?
    @State private var collapsedWorkspaceGroupIDs: Set<String> = []
    @State private var collapsedSessionNodeKeys: Set<ThreadKey> = []
    @State private var pendingActiveSessionScroll = false
    @State private var sessionSearchDebounceTask: Task<Void, Never>?
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
    private static let absoluteDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
    private struct DirectoryPickerSheetModel: Identifiable, Equatable {
        let id: UUID = UUID()
        var selectedServerId: String
    }

    var body: some View {
        let derived = makeDerivedData()
        return sidebarContent(derived: derived)
    }

    private func sidebarContent(derived: SessionSidebarDerivedData) -> some View {
        let base = sidebarLayout(derived: derived)
            .background(.ultraThinMaterial)
            .enableInjection()

        let lifecycle = attachLifecycleHandlers(to: base, derived: derived)
        let alerts = attachSheetAndAlerts(to: lifecycle)

        return alerts.sheet(item: $directoryPickerSheet) { _ in
            NavigationStack {
                DirectoryPickerView(
                    servers: connectedServerOptions,
                    selectedServerId: Binding(
                        get: { directoryPickerSheet?.selectedServerId ?? defaultNewSessionServerId() ?? "" },
                        set: { nextServerId in
                            guard var sheet = directoryPickerSheet else { return }
                            sheet.selectedServerId = nextServerId
                            directoryPickerSheet = sheet
                        }
                    ),
                    onServerChanged: { nextServerId in
                        guard var sheet = directoryPickerSheet else { return }
                        sheet.selectedServerId = nextServerId
                        directoryPickerSheet = sheet
                    },
                    onDirectorySelected: { serverId, cwd in
                        directoryPickerSheet = nil
                        Task { await startNewSession(serverId: serverId, cwd: cwd) }
                    },
                    onDismissRequested: {
                        directoryPickerSheet = nil
                    }
                )
                .environmentObject(serverManager)
            }
            .preferredColorScheme(.dark)
        }
    }

    private func attachLifecycleHandlers<Content: View>(
        to content: Content,
        derived: SessionSidebarDerivedData
    ) -> some View {
        let primaryLifecycle = AnyView(
            content
                .task { await loadSessions() }
                .onAppear {
                    scheduleActiveSessionScrollIfNeeded()
                }
                .onChange(of: serverManager.hasAnyConnection) { _, connected in
                    if connected { Task { await loadSessions() } }
                }
                .onChange(of: serverManager.activeThreadKey) { _, _ in
                    scheduleActiveSessionScrollIfNeeded()
                }
                .onChange(of: appState.sidebarOpen) { _, isOpen in
                    if isOpen {
                        scheduleActiveSessionScrollIfNeeded()
                    } else {
                        sessionSearchQuery = ""
                        debouncedSessionSearchQuery = ""
                        pendingActiveSessionScroll = false
                    }
                }
        )

        let secondaryLifecycle = AnyView(
            primaryLifecycle
                .onChange(of: connectedServerIds) { _, ids in
                    guard let pickerSheet = directoryPickerSheet else {
                        if let filterId = selectedServerFilterId, !ids.contains(filterId) {
                            selectedServerFilterId = nil
                        }
                        return
                    }
                    guard let fallbackServerId = defaultNewSessionServerId(preferredServerId: pickerSheet.selectedServerId) else {
                        directoryPickerSheet = nil
                        appState.showServerPicker = true
                        return
                    }
                    if pickerSheet.selectedServerId != fallbackServerId {
                        var nextSheet = pickerSheet
                        nextSheet.selectedServerId = fallbackServerId
                        directoryPickerSheet = nextSheet
                    }
                    if let filterId = selectedServerFilterId, !ids.contains(filterId) {
                        selectedServerFilterId = nil
                    }
                }
                .onChange(of: sessionSearchQuery) { _, next in
                    scheduleSessionSearchDebounce(for: next)
                }
        )

        return secondaryLifecycle
            .onChange(of: derived.workspaceGroupIDs) { _, ids in
                let idSet: Set<String> = Set(ids)
                collapsedWorkspaceGroupIDs = collapsedWorkspaceGroupIDs.intersection(idSet)
            }
            .onChange(of: derived.allThreadKeys) { _, keys in
                let keySet: Set<ThreadKey> = Set(keys)
                collapsedSessionNodeKeys = collapsedSessionNodeKeys.intersection(keySet)
            }
            .onDisappear {
                sessionSearchDebounceTask?.cancel()
                sessionSearchDebounceTask = nil
            }
    }

    private func attachSheetAndAlerts<Content: View>(to content: Content) -> some View {
        content
            .sheet(isPresented: $showSettings) {
                SettingsView().environmentObject(serverManager)
            }
            .alert("Session Action Failed", isPresented: Binding(
                get: { sessionActionErrorMessage != nil },
                set: { if !$0 { sessionActionErrorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sessionActionErrorMessage = nil }
            } message: {
                Text(sessionActionErrorMessage ?? "Unknown error")
            }
            .alert("Rename Session", isPresented: Binding(
                get: { renamingThreadKey != nil },
                set: {
                    if !$0 {
                        renamingThreadKey = nil
                        renameCurrentTitle = ""
                        renameDraft = ""
                    }
                }
            )) {
                TextField("New session title", text: $renameDraft)
                Button("Save") { Task { await submitRename() } }
                Button("Cancel", role: .cancel) {
                    renamingThreadKey = nil
                    renameCurrentTitle = ""
                    renameDraft = ""
                }
            } message: {
                Text("Current session title:\n\(renameCurrentTitle)")
            }
            .confirmationDialog(
                "Delete session?",
                isPresented: Binding(
                    get: { archiveTargetKey != nil },
                    set: { if !$0 { archiveTargetKey = nil } }
                ),
                titleVisibility: Visibility.visible,
                presenting: archiveTargetThread
            ) { thread in
                Button("Delete \"\(sessionTitle(thread))\"", role: .destructive) {
                    Task { await confirmArchiveSession() }
                }
                Button("Cancel", role: .cancel) { archiveTargetKey = nil }
            } message: { _ in
                Text("This removes the session from the list.")
            }
    }

    private func sidebarLayout(derived: SessionSidebarDerivedData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            newSessionButton
            Divider().background(LitterTheme.separator)
            serversRow
            Divider().background(LitterTheme.separator)

            if isLoading {
                Spacer()
                ProgressView().tint(LitterTheme.accent).frame(maxWidth: .infinity)
                Spacer()
            } else if derived.allThreads.isEmpty {
                Spacer()
                Text("No sessions yet")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                sessionSearchBar
                sessionFilterRow
                Divider().background(LitterTheme.separator)
                if derived.filteredThreads.isEmpty {
                    Spacer()
                    Text("No matches for \"\(trimmedSessionSearchQuery)\"")
                        .font(LitterFont.monospaced(.footnote))
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    sessionList(derived: derived)
                }
            }

            Divider().background(LitterTheme.separator)
            settingsRow
        }
    }

    private var selectedServerFilterId: String? {
        get { appState.sessionSidebarSelectedServerFilterId }
        nonmutating set { appState.sessionSidebarSelectedServerFilterId = newValue }
    }

    private var showOnlyForks: Bool {
        get { appState.sessionSidebarShowOnlyForks }
        nonmutating set { appState.sessionSidebarShowOnlyForks = newValue }
    }

    private var workspaceSortMode: WorkspaceSortMode {
        get { WorkspaceSortMode(rawValue: appState.sessionSidebarWorkspaceSortModeRaw) ?? .mostRecent }
        nonmutating set { appState.sessionSidebarWorkspaceSortModeRaw = newValue.rawValue }
    }

    private var connectedServerIds: [String] {
        connectedServerOptions.map(\.id)
    }

    private var trimmedSessionSearchQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedDebouncedSessionSearchQuery: String {
        debouncedSessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var archiveTargetThread: ThreadState? {
        guard let archiveTargetKey else { return nil }
        return serverManager.threads[archiveTargetKey]
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

    private func scheduleSessionSearchDebounce(for nextQuery: String) {
        sessionSearchDebounceTask?.cancel()
        sessionSearchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let normalized = nextQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if debouncedSessionSearchQuery != normalized {
                debouncedSessionSearchQuery = normalized
            }
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
                    .font(LitterFont.monospaced(.footnote))
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
                directoryPickerSheet = DirectoryPickerSheetModel(selectedServerId: defaultServerId)
            } else {
                appState.showServerPicker = true
            }
        } label: {
            HStack {
                Image(systemName: "plus")
                    .font(.system(.subheadline, weight: .medium))
                Text("New Session")
                    .font(LitterFont.monospaced(.subheadline))
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
            let activeThread = serverManager.activeThread
            if connected.isEmpty {
                Image(systemName: "xmark.circle")
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(width: 20)
                Text("Not connected")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(LitterTheme.textMuted)
                Spacer()
                Button("Connect") {
                    withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
                    appState.showServerPicker = true
                }
                .font(LitterFont.monospaced(.caption))
                .foregroundColor(LitterTheme.accent)
            } else {
                Image(systemName: "server.rack")
                    .foregroundColor(LitterTheme.accent)
                    .frame(width: 20)
                Text("\(connected.count) server\(connected.count == 1 ? "" : "s")")
                    .font(LitterFont.monospaced(.footnote))
                    .foregroundColor(.white)
                Spacer()
                Button("Add") {
                    withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
                    appState.showServerPicker = true
                }
                .font(LitterFont.monospaced(.caption))
                .foregroundColor(LitterTheme.accent)
                if let activeThread {
                    Button {
                        Task { await forkThread(activeThread) }
                    } label: {
                        if isForkingActiveThread {
                            ProgressView()
                                .controlSize(.small)
                                .tint(LitterTheme.accent)
                        } else {
                            Text("Fork")
                        }
                    }
                    .disabled(isForkingActiveThread || activeThread.hasTurnActive)
                    .font(LitterFont.monospaced(.caption))
                    .foregroundColor(activeThread.hasTurnActive ? LitterTheme.textMuted : LitterTheme.accent)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var sessionSearchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(LitterTheme.textMuted)
                .font(LitterFont.monospaced(.caption))

            TextField("Search sessions", text: $sessionSearchQuery)
                .font(LitterFont.monospaced(.footnote))
                .foregroundColor(.white)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)

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

    private var sessionFilterRow: some View {
        HStack(spacing: 8) {
            Menu {
                Button("All servers") { selectedServerFilterId = nil }
                ForEach(connectedServerOptions, id: \.id) { option in
                    Button(option.name) { selectedServerFilterId = option.id }
                }
            } label: {
                filterChip(
                    title: selectedServerFilterTitle,
                    isActive: selectedServerFilterId != nil,
                    icon: "server.rack"
                )
            }
            .buttonStyle(.plain)

            Button {
                showOnlyForks.toggle()
            } label: {
                filterChip(
                    title: "Forks",
                    isActive: showOnlyForks,
                    icon: "arrow.triangle.branch"
                )
            }
            .buttonStyle(.plain)

            Menu {
                ForEach(WorkspaceSortMode.allCases) { mode in
                    Button(mode.title) { workspaceSortMode = mode }
                }
            } label: {
                filterChip(
                    title: workspaceSortMode.title,
                    isActive: workspaceSortMode != .mostRecent,
                    icon: "arrow.up.arrow.down"
                )
            }
            .buttonStyle(.plain)

            if selectedServerFilterId != nil || showOnlyForks {
                Button("Clear") {
                    selectedServerFilterId = nil
                    showOnlyForks = false
                }
                .font(LitterFont.monospaced(.caption))
                .foregroundColor(LitterTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var selectedServerFilterTitle: String {
        guard let selectedServerFilterId else { return "All servers" }
        return connectedServerOptions.first(where: { $0.id == selectedServerFilterId })?.name ?? "All servers"
    }

    private func filterChip(title: String, isActive: Bool, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
            Text(title)
                .lineLimit(1)
        }
        .font(LitterFont.monospaced(.caption))
        .foregroundColor(isActive ? .black : LitterTheme.textSecondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isActive ? LitterTheme.accent : LitterTheme.surface.opacity(0.65))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isActive ? LitterTheme.accent : LitterTheme.border.opacity(0.7), lineWidth: 1)
        )
        .cornerRadius(7)
    }

    private func workspaceGroupHeader(_ group: WorkspaceSessionGroup) -> some View {
        let isCollapsed = collapsedWorkspaceGroupIDs.contains(group.id)
        let countLabel = group.threads.count == 1 ? "1 session" : "\(group.threads.count) sessions"
        let detailLine = group.workspacePath == group.workspaceTitle
            ? "\(group.serverName) • \(countLabel)"
            : "\(group.serverName) • \(group.workspacePath) • \(countLabel)"

        return Button {
            if isCollapsed {
                collapsedWorkspaceGroupIDs.remove(group.id)
            } else {
                collapsedWorkspaceGroupIDs.insert(group.id)
            }
        } label: {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(width: 12)

                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.workspaceTitle)
                        .font(LitterFont.monospaced(.caption))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Text(detailLine)
                        .font(LitterFont.monospaced(.caption2))
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(LitterTheme.border.opacity(0.75))
                    .frame(height: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func sessionList(derived: SessionSidebarDerivedData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(derived.workspaceSections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(LitterFont.monospaced(.caption2))
                                .foregroundColor(LitterTheme.textMuted)
                                .padding(.horizontal, 2)
                        }

                        ForEach(section.groups) { group in
                            workspaceGroupHeader(group)

                            if !collapsedWorkspaceGroupIDs.contains(group.id) {
                                ForEach(visibleSessionRows(for: group)) { row in
                                    let thread = row.thread
                                    let isCollapsed = collapsedSessionNodeKeys.contains(thread.key)

                                    sessionRow(
                                        thread,
                                        isActive: thread.key == serverManager.activeThreadKey,
                                        derived: derived,
                                        depth: row.depth,
                                        hasChildren: row.hasChildren,
                                        isCollapsed: isCollapsed,
                                        onToggleNode: {
                                            guard row.hasChildren else { return }
                                            if isCollapsed {
                                                collapsedSessionNodeKeys.remove(thread.key)
                                            } else {
                                                collapsedSessionNodeKeys.insert(thread.key)
                                            }
                                        },
                                        onSelectSession: {
                                            guard resumingKey == nil else { return }
                                            Task { await resumeSession(thread) }
                                        }
                                    )
                                    .id(thread.key)
                                    .contextMenu {
                                        sessionRowContextMenu(thread)
                                    }
                                    .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                        Button {
                                            Task { await forkThread(thread) }
                                        } label: {
                                            Label("Fork", systemImage: "arrow.triangle.branch")
                                        }
                                        .tint(LitterTheme.accent)
                                    }
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            archiveTargetKey = thread.key
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 4)
                .padding(.trailing, 8)
                .padding(.vertical, 4)
            }
            .onAppear {
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: pendingActiveSessionScroll) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: derived.filteredThreadKeys) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: collapsedWorkspaceGroupIDs) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
            .onChange(of: collapsedSessionNodeKeys) { _, _ in
                scrollToActiveSessionIfNeeded(derived: derived, proxy: proxy)
            }
        }
    }

    @ViewBuilder
    private func sessionRowContextMenu(_ thread: ThreadState) -> some View {
        Button {
            renamingThreadKey = thread.key
            renameCurrentTitle = sessionTitle(thread)
            renameDraft = ""
        } label: {
            Label("Rename", systemImage: "pencil")
        }

        Button {
            Task { await forkThread(thread) }
        } label: {
            Label("Fork", systemImage: "arrow.triangle.branch")
        }

        Button(role: .destructive) {
            archiveTargetKey = thread.key
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private func sessionRow(
        _ thread: ThreadState,
        isActive: Bool,
        derived: SessionSidebarDerivedData,
        depth: Int,
        hasChildren: Bool,
        isCollapsed: Bool,
        onToggleNode: @escaping () -> Void,
        onSelectSession: @escaping () -> Void
    ) -> some View {
        let parent = derived.parentByKey[thread.key]

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: CGFloat(depth) * 8)
                    if hasChildren {
                        Button(action: onToggleNode) {
                            Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundColor(LitterTheme.textSecondary)
                                .frame(width: 10, height: 10)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(width: 10, height: 10)
                    }
                }
                .padding(.top, 2)

                HStack(alignment: .top, spacing: 6) {
                    if thread.hasTurnActive {
                        PulsingDot().padding(.top, 3)
                    } else {
                        Circle().fill(Color.clear).frame(width: 8, height: 8).padding(.top, 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(sessionTitle(thread))
                                .font(LitterFont.monospaced(.footnote))
                                .foregroundColor(.white)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)

                            if thread.isFork {
                                Text("Fork")
                                    .font(LitterFont.monospaced(.caption2))
                                    .foregroundColor(.black)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(LitterTheme.accent)
                                    .cornerRadius(4)
                            }

                            Spacer(minLength: 0)

                            if resumingKey == thread.key {
                                ProgressView()
                                    .controlSize(.small)
                                    .tint(LitterTheme.accent)
                            }
                        }

                        Text(sessionMetadataLine(thread))
                            .font(LitterFont.monospaced(.caption))
                            .foregroundColor(LitterTheme.textSecondary)
                            .lineLimit(1)

                        if let parent {
                            Text("from \(sessionTitle(parent))")
                                .font(LitterFont.monospaced(.caption2))
                                .foregroundColor(LitterTheme.textMuted)
                                .lineLimit(1)
                        }

                        if !thread.cwd.isEmpty {
                            Text(thread.cwd)
                                .font(LitterFont.monospaced(.caption2))
                                .foregroundColor(LitterTheme.textMuted)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture(perform: onSelectSession)
            }

            if isActive {
                lineageSummary(for: thread, derived: derived)
            }
        }
        .padding(.leading, 1)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background {
            if isActive {
                RoundedRectangle(cornerRadius: 6)
                    .fill(LitterTheme.surfaceLight.opacity(0.55))
            }
        }
    }

    private func lineageSummary(for thread: ThreadState, derived: SessionSidebarDerivedData) -> some View {
        let parent = derived.parentByKey[thread.key]
        let siblings = derived.siblingsByKey[thread.key] ?? []
        let children = derived.childrenByKey[thread.key] ?? []
        let hasLineage = parent != nil || !siblings.isEmpty || !children.isEmpty

        return Group {
            if hasLineage {
                VStack(alignment: .leading, spacing: 5) {
                    Divider().background(LitterTheme.border.opacity(0.7))

                    HStack(spacing: 6) {
                        if let parent {
                            Button {
                                Task { await resumeSession(parent) }
                            } label: {
                                lineageChip(title: "Parent", count: 1, isInteractive: true)
                            }
                            .buttonStyle(.plain)
                        }

                        if !siblings.isEmpty {
                            Menu {
                                ForEach(siblings) { sibling in
                                    Button(sessionTitle(sibling)) {
                                        Task { await resumeSession(sibling) }
                                    }
                                }
                            } label: {
                                lineageChip(title: "Siblings", count: siblings.count, isInteractive: true)
                            }
                        }

                        if !children.isEmpty {
                            Menu {
                                ForEach(children) { child in
                                    Button(sessionTitle(child)) {
                                        Task { await resumeSession(child) }
                                    }
                                }
                            } label: {
                                lineageChip(title: "Children", count: children.count, isInteractive: true)
                            }
                        }

                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    private func lineageChip(title: String, count: Int, isInteractive: Bool) -> some View {
        Text("\(title) \(count)")
            .font(LitterFont.monospaced(.caption2))
            .foregroundColor(isInteractive ? LitterTheme.accent : LitterTheme.textMuted)
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .background(LitterTheme.surface.opacity(0.8))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(isInteractive ? LitterTheme.accent.opacity(0.5) : LitterTheme.border.opacity(0.5), lineWidth: 1)
            )
            .cornerRadius(5)
    }

    private func visibleSessionRows(for group: WorkspaceSessionGroup) -> [SessionTreeRow] {
        var rows: [SessionTreeRow] = []

        func append(nodes: [SessionTreeNode], depth: Int) {
            for node in nodes {
                let hasChildren = !node.children.isEmpty
                rows.append(
                    SessionTreeRow(
                        thread: node.thread,
                        depth: depth,
                        hasChildren: hasChildren
                    )
                )

                if hasChildren && !collapsedSessionNodeKeys.contains(node.thread.key) {
                    append(nodes: node.children, depth: depth + 1)
                }
            }
        }

        append(nodes: group.treeRoots, depth: 0)
        return rows
    }

    private func scheduleActiveSessionScrollIfNeeded() {
        guard appState.sidebarOpen, serverManager.activeThreadKey != nil else { return }
        pendingActiveSessionScroll = true
    }

    private func scrollToActiveSessionIfNeeded(derived: SessionSidebarDerivedData, proxy: ScrollViewProxy) {
        guard pendingActiveSessionScroll, appState.sidebarOpen, let activeKey = serverManager.activeThreadKey else { return }

        guard let activeThread = derived.filteredThreads.first(where: { $0.key == activeKey }) else {
            pendingActiveSessionScroll = false
            return
        }

        let activeWorkspaceGroupID = workspaceGroupID(for: activeThread)
        if collapsedWorkspaceGroupIDs.contains(activeWorkspaceGroupID) {
            collapsedWorkspaceGroupIDs.remove(activeWorkspaceGroupID)
            return
        }

        if let collapsedAncestor = ancestorThreadKeys(for: activeKey, derived: derived)
            .reversed()
            .first(where: { collapsedSessionNodeKeys.contains($0) }) {
            collapsedSessionNodeKeys.remove(collapsedAncestor)
            return
        }

        pendingActiveSessionScroll = false
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(activeKey, anchor: .center)
        }
    }

    private func ancestorThreadKeys(for key: ThreadKey, derived: SessionSidebarDerivedData) -> [ThreadKey] {
        var ancestors: [ThreadKey] = []
        var visited: Set<ThreadKey> = []
        var cursor: ThreadState? = derived.parentByKey[key]

        while let thread = cursor, !visited.contains(thread.key) {
            ancestors.append(thread.key)
            visited.insert(thread.key)
            cursor = derived.parentByKey[thread.key]
        }

        return ancestors
    }

    private func workspaceGroupID(for thread: ThreadState) -> String {
        "\(thread.serverId)::\(normalizedWorkspacePath(thread.cwd))"
    }

    private func normalizedWorkspacePath(_ raw: String) -> String {
        var path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            return "/"
        }
        path = path.replacingOccurrences(of: "/+", with: "/", options: .regularExpression)
        while path.count > 1 && path.hasSuffix("/") {
            path.removeLast()
        }
        return path.isEmpty ? "/" : path
    }

    private func workspaceTitle(for workspacePath: String) -> String {
        if workspacePath == "/" {
            return "/"
        }
        let name = URL(fileURLWithPath: workspacePath).lastPathComponent
        return name.isEmpty ? workspacePath : name
    }

    private func sessionTitle(_ thread: ThreadState) -> String {
        thread.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Untitled session" : thread.preview
    }

    private func sessionMetadataLine(_ thread: ThreadState) -> String {
        let provider = thread.modelProvider.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerLabel = provider.isEmpty ? "default" : provider
        return "\(relativeDate(thread.updatedAt)) • \(thread.serverName) • \(providerLabel)"
    }

    private func sanitizedLineageId(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func sortWorkspaceGroups(_ groups: [WorkspaceSessionGroup]) -> [WorkspaceSessionGroup] {
        groups.sorted { (lhs: WorkspaceSessionGroup, rhs: WorkspaceSessionGroup) in
            switch workspaceSortMode {
            case .mostRecent:
                if lhs.latestUpdatedAt != rhs.latestUpdatedAt {
                    return lhs.latestUpdatedAt > rhs.latestUpdatedAt
                }
                return lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle) == .orderedAscending
            case .name:
                let titleOrder = lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                let pathOrder = lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath)
                if pathOrder != .orderedSame {
                    return pathOrder == .orderedAscending
                }
                let serverOrder = lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName)
                if serverOrder != .orderedSame {
                    return serverOrder == .orderedAscending
                }
                return lhs.latestUpdatedAt > rhs.latestUpdatedAt
            case .date:
                if lhs.latestUpdatedAt != rhs.latestUpdatedAt {
                    return lhs.latestUpdatedAt > rhs.latestUpdatedAt
                }
                let titleOrder = lhs.workspaceTitle.localizedCaseInsensitiveCompare(rhs.workspaceTitle)
                if titleOrder != .orderedSame {
                    return titleOrder == .orderedAscending
                }
                let pathOrder = lhs.workspacePath.localizedCaseInsensitiveCompare(rhs.workspacePath)
                if pathOrder != .orderedSame {
                    return pathOrder == .orderedAscending
                }
                return lhs.serverName.localizedCaseInsensitiveCompare(rhs.serverName) == .orderedAscending
            }
        }
    }

    private func workspaceSections(for groups: [WorkspaceSessionGroup]) -> [WorkspaceGroupSection] {
        guard workspaceSortMode == .date else {
            guard !groups.isEmpty else { return [] }
            return [WorkspaceGroupSection(id: "all", title: nil, groups: groups)]
        }

        let calendar = Calendar.current
        var groupsByDay: [Date: [WorkspaceSessionGroup]] = [:]
        for group in groups {
            let dayStart = calendar.startOfDay(for: group.latestUpdatedAt)
            groupsByDay[dayStart, default: []].append(group)
        }

        return groupsByDay.keys
            .sorted(by: >)
            .map { dayStart in
                WorkspaceGroupSection(
                    id: "day-\(Int(dayStart.timeIntervalSince1970))",
                    title: workspaceDateSectionLabel(for: dayStart),
                    groups: groupsByDay[dayStart] ?? []
                )
            }
    }

    private func workspaceDateSectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: date)
        let nowStart = calendar.startOfDay(for: Date())
        let dayDelta = max(calendar.dateComponents([.day], from: dayStart, to: nowStart).day ?? 0, 0)

        switch dayDelta {
        case 0:
            return "Today"
        case 1:
            return "Yesterday"
        case 2 ... 6:
            return "\(dayDelta) days ago"
        default:
            return Self.absoluteDateFormatter.string(from: dayStart)
        }
    }

    private func makeDerivedData() -> SessionSidebarDerivedData {
        let allThreads = serverManager.sortedThreads

        var threadsByServerAndId: [String: [String: ThreadState]] = [:]
        var childrenByServerAndParentId: [String: [String: [ThreadState]]] = [:]
        var parentIdByThreadKey: [ThreadKey: String] = [:]

        for thread in allThreads {
            threadsByServerAndId[thread.serverId, default: [:]][thread.threadId] = thread
            if let parentId = sanitizedLineageId(thread.parentThreadId) {
                parentIdByThreadKey[thread.key] = parentId
                childrenByServerAndParentId[thread.serverId, default: [:]][parentId, default: []].append(thread)
            }
        }

        let sortedChildrenByServerAndParentId = childrenByServerAndParentId.mapValues { parentMap in
            parentMap.mapValues { children in
                children.sorted { $0.updatedAt > $1.updatedAt }
            }
        }

        var parentByKey: [ThreadKey: ThreadState] = [:]
        var siblingsByKey: [ThreadKey: [ThreadState]] = [:]
        var childrenByKey: [ThreadKey: [ThreadState]] = [:]

        for thread in allThreads {
            let serverThreads = threadsByServerAndId[thread.serverId] ?? [:]
            if let parentId = parentIdByThreadKey[thread.key],
               let parent = serverThreads[parentId] {
                parentByKey[thread.key] = parent
                let siblingCandidates = sortedChildrenByServerAndParentId[thread.serverId]?[parentId] ?? []
                siblingsByKey[thread.key] = siblingCandidates.filter { $0.threadId != thread.threadId }
            } else {
                siblingsByKey[thread.key] = []
            }
            childrenByKey[thread.key] = sortedChildrenByServerAndParentId[thread.serverId]?[thread.threadId] ?? []
        }

        let query = trimmedDebouncedSessionSearchQuery
        let filteredThreads = allThreads.filter { thread in
            if let selectedServerFilterId, thread.serverId != selectedServerFilterId {
                return false
            }
            if showOnlyForks && !thread.isFork {
                return false
            }
            if query.isEmpty {
                return true
            }
            let parentTitle = parentByKey[thread.key].map(sessionTitle) ?? ""
            return sessionTitle(thread).localizedCaseInsensitiveContains(query) ||
                thread.cwd.localizedCaseInsensitiveContains(query) ||
                thread.serverName.localizedCaseInsensitiveContains(query) ||
                thread.modelProvider.localizedCaseInsensitiveContains(query) ||
                parentTitle.localizedCaseInsensitiveContains(query)
        }

        let groupedByWorkspace = Dictionary(grouping: filteredThreads) { workspaceGroupID(for: $0) }
        let groupedWorkspaceGroups = groupedByWorkspace
            .compactMap { (groupID: String, threads: [ThreadState]) -> WorkspaceSessionGroup? in
                let sortedThreads = threads.sorted { $0.updatedAt > $1.updatedAt }
                guard let first = sortedThreads.first else { return nil }
                let workspacePath = normalizedWorkspacePath(first.cwd)
                let treeRoots = buildSessionTree(for: sortedThreads, parentByKey: parentByKey)
                return WorkspaceSessionGroup(
                    id: groupID,
                    serverId: first.serverId,
                    serverName: first.serverName,
                    workspacePath: workspacePath,
                    workspaceTitle: workspaceTitle(for: workspacePath),
                    latestUpdatedAt: first.updatedAt,
                    threads: sortedThreads,
                    treeRoots: treeRoots
                )
            }
        let sortedWorkspaceGroups = sortWorkspaceGroups(groupedWorkspaceGroups)
        let workspaceSections = workspaceSections(for: sortedWorkspaceGroups)

        return SessionSidebarDerivedData(
            allThreads: allThreads,
            allThreadKeys: allThreads.map(\.key),
            filteredThreads: filteredThreads,
            filteredThreadKeys: filteredThreads.map(\.key),
            workspaceSections: workspaceSections,
            workspaceGroupIDs: sortedWorkspaceGroups.map { $0.id },
            parentByKey: parentByKey,
            siblingsByKey: siblingsByKey,
            childrenByKey: childrenByKey
        )
    }

    private func buildSessionTree(
        for threads: [ThreadState],
        parentByKey: [ThreadKey: ThreadState]
    ) -> [SessionTreeNode] {
        let threadsByKey = Dictionary(uniqueKeysWithValues: threads.map { ($0.key, $0) })
        var childrenByParentKey: [ThreadKey: [ThreadState]] = [:]

        for thread in threads {
            guard let parent = parentByKey[thread.key], threadsByKey[parent.key] != nil else { continue }
            childrenByParentKey[parent.key, default: []].append(thread)
        }
        childrenByParentKey = childrenByParentKey.mapValues { children in
            children.sorted { $0.updatedAt > $1.updatedAt }
        }

        var emitted: Set<ThreadKey> = []

        func makeNode(_ thread: ThreadState, path: inout Set<ThreadKey>) -> SessionTreeNode {
            path.insert(thread.key)
            let children = (childrenByParentKey[thread.key] ?? []).compactMap { child -> SessionTreeNode? in
                guard !path.contains(child.key), emitted.insert(child.key).inserted else { return nil }
                return makeNode(child, path: &path)
            }
            path.remove(thread.key)
            return SessionTreeNode(thread: thread, children: children)
        }

        let roots = threads.filter { thread in
            guard let parent = parentByKey[thread.key] else { return true }
            return threadsByKey[parent.key] == nil
        }

        var treeRoots: [SessionTreeNode] = []
        for root in roots {
            guard emitted.insert(root.key).inserted else { continue }
            var path: Set<ThreadKey> = []
            treeRoots.append(makeNode(root, path: &path))
        }

        for thread in threads where !emitted.contains(thread.key) {
            emitted.insert(thread.key)
            var path: Set<ThreadKey> = []
            treeRoots.append(makeNode(thread, path: &path))
        }

        return treeRoots
    }

    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private func loadSessions() async {
        let signpostID = OSSignpostID(log: sessionSidebarSignpostLog)
        os_signpost(.begin, log: sessionSidebarSignpostLog, name: "LoadSessions", signpostID: signpostID)
        defer { os_signpost(.end, log: sessionSidebarSignpostLog, name: "LoadSessions", signpostID: signpostID) }

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
        let startedKey = await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        if startedKey != nil {
            _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        }
        withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
    }

    private func forkThread(_ thread: ThreadState) async {
        guard !isForkingActiveThread else { return }
        isForkingActiveThread = true
        defer { isForkingActiveThread = false }
        do {
            _ = try await serverManager.forkThread(
                thread.key,
                cwd: thread.cwd,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
            if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
            withAnimation(.easeInOut(duration: 0.25)) { appState.sidebarOpen = false }
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
    }

    private func submitRename() async {
        guard let key = renamingThreadKey else { return }
        let nextTitle = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !nextTitle.isEmpty else { return }
        do {
            try await serverManager.renameThread(key, to: nextTitle)
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
        renamingThreadKey = nil
        renameCurrentTitle = ""
        renameDraft = ""
    }

    private func confirmArchiveSession() async {
        guard let key = archiveTargetKey else { return }
        do {
            let previousActiveKey = serverManager.activeThreadKey
            try await serverManager.archiveThread(key)
            let nextActiveKey = serverManager.activeThreadKey
            if nextActiveKey != previousActiveKey {
                let nextCwd = serverManager.activeThread?.cwd.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
        } catch {
            sessionActionErrorMessage = error.localizedDescription
        }
        archiveTargetKey = nil
    }

    private func relativeDate(_ date: Date) -> String {
        Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
    }
}

private enum WorkspaceSortMode: String, CaseIterable, Identifiable {
    case mostRecent
    case name
    case date

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mostRecent:
            return "Most Recent"
        case .name:
            return "Name"
        case .date:
            return "Date"
        }
    }
}

private struct WorkspaceSessionGroup: Identifiable {
    let id: String
    let serverId: String
    let serverName: String
    let workspacePath: String
    let workspaceTitle: String
    let latestUpdatedAt: Date
    let threads: [ThreadState]
    let treeRoots: [SessionTreeNode]
}

private struct WorkspaceGroupSection: Identifiable {
    let id: String
    let title: String?
    let groups: [WorkspaceSessionGroup]
}

private struct SessionTreeNode: Identifiable {
    let thread: ThreadState
    let children: [SessionTreeNode]

    var id: ThreadKey { thread.key }
}

private struct SessionTreeRow: Identifiable {
    let thread: ThreadState
    let depth: Int
    let hasChildren: Bool

    var id: ThreadKey { thread.key }
}

private struct SessionSidebarDerivedData {
    let allThreads: [ThreadState]
    let allThreadKeys: [ThreadKey]
    let filteredThreads: [ThreadState]
    let filteredThreadKeys: [ThreadKey]
    let workspaceSections: [WorkspaceGroupSection]
    let workspaceGroupIDs: [String]
    let parentByKey: [ThreadKey: ThreadState]
    let siblingsByKey: [ThreadKey: [ThreadState]]
    let childrenByKey: [ThreadKey: [ThreadState]]
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
