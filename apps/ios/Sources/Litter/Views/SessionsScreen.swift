import SwiftUI
import Inject
import os

private let sessionsScreenSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "SessionsScreen"
)

struct SessionsScreen: View {
    @ObserveInjection var inject
    @Environment(ServerManager.self) private var serverManager
    @Environment(AppState.self) private var appState
    @Environment(ConversationWarmupCoordinator.self) private var conversationWarmup
    @State private var sessionsModel = SessionsModel()
    @State private var isLoading: Bool
    @State private var resumingKey: ThreadKey?
    @State private var isStartingNewSession = false
    @State private var directoryPickerSheet: SessionLaunchSupport.DirectoryPickerSheetModel?
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
    @State private var hasLoadedInitialSessions = false
    private let autoLoadSessions: Bool
    private let onOpenConversation: (ThreadKey) -> Void
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    init(
        autoLoadSessions: Bool = true,
        onOpenConversation: @escaping (ThreadKey) -> Void
    ) {
        self.autoLoadSessions = autoLoadSessions
        self.onOpenConversation = onOpenConversation
        _isLoading = State(initialValue: autoLoadSessions)
    }

    var body: some View {
        screenContent(derived: sessionsModel.derivedData)
    }


    private func screenContent(derived: SessionsDerivedData) -> some View {
        let base = screenLayout(derived: derived)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
            }
            .environment(serverManager)
        }
    }

    private func attachLifecycleHandlers<Content: View>(
        to content: Content,
        derived: SessionsDerivedData
    ) -> some View {
        content
            .task {
                sessionsModel.bind(serverManager: serverManager, appState: appState)
                sessionsModel.updateSearchQuery(debouncedSessionSearchQuery)
                await loadSessionsIfNeeded()
            }
            .onAppear {
                scheduleActiveSessionScrollIfNeeded()
            }
            .onChange(of: serverManager.hasAnyConnection) { _, connected in
                guard autoLoadSessions, connected else { return }
                Task { await loadSessionsIfNeeded(force: true) }
            }
            .onChange(of: serverManager.activeThreadKey) { _, _ in
                scheduleActiveSessionScrollIfNeeded()
            }
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
            .onChange(of: debouncedSessionSearchQuery) { _, next in
                sessionsModel.updateSearchQuery(next)
            }
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
                Button("Delete \"\(thread.sessionTitle)\"", role: .destructive) {
                    Task { await confirmArchiveSession() }
                }
                Button("Cancel", role: .cancel) { archiveTargetKey = nil }
            } message: { _ in
                Text("This removes the session from the list.")
            }
    }

    private func screenLayout(derived: SessionsDerivedData) -> some View {
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
                    .font(LitterFont.styled(.footnote))
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
                        .font(LitterFont.styled(.footnote))
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    sessionList(derived: derived)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }

        }
        .accessibilityIdentifier("sessions.container")
    }

    private var selectedServerFilterId: String? {
        get { appState.sessionsSelectedServerFilterId }
        nonmutating set { appState.sessionsSelectedServerFilterId = newValue }
    }

    private var showOnlyForks: Bool {
        get { appState.sessionsShowOnlyForks }
        nonmutating set { appState.sessionsShowOnlyForks = newValue }
    }

    private var workspaceSortMode: WorkspaceSortMode {
        get { WorkspaceSortMode(rawValue: appState.sessionsWorkspaceSortModeRaw) ?? .mostRecent }
        nonmutating set { appState.sessionsWorkspaceSortModeRaw = newValue.rawValue }
    }

    private var connectedServerIds: [String] {
        connectedServerOptions.map(\.id)
    }

    private var trimmedSessionSearchQuery: String {
        sessionSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var archiveTargetThread: ThreadState? {
        guard let archiveTargetKey else { return nil }
        return serverManager.threads[archiveTargetKey]
    }

    private var connectedServerOptions: [DirectoryPickerServerOption] {
        sessionsModel.connectedServerOptions
    }

    private var ephemeralStateByThreadKey: [ThreadKey: SessionsModel.ThreadEphemeralState] {
        sessionsModel.ephemeralStateByThreadKey
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
        SessionLaunchSupport.defaultConnectedServerId(
            connectedServerIds: connectedServerIds,
            activeThreadKey: serverManager.activeThreadKey,
            preferredServerId: preferredServerId
        )
    }

    private var newSessionButton: some View {
        HStack(spacing: 10) {
            Button { appState.showSettings = true } label: {
                Image(systemName: "gear")
                    .font(.system(.subheadline, weight: .medium))
                    .foregroundColor(LitterTheme.textSecondary)
                    .frame(width: 44, height: 44)
                    .modifier(GlassRectModifier(cornerRadius: 10))
            }
            .accessibilityIdentifier("sessions.settingsButton")

            Button {
                if let defaultServerId = defaultNewSessionServerId() {
                    directoryPickerSheet = SessionLaunchSupport.DirectoryPickerSheetModel(selectedServerId: defaultServerId)
                } else {
                    appState.showServerPicker = true
                }
            } label: {
                HStack {
                    if isStartingNewSession {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LitterTheme.textOnAccent)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(.subheadline, weight: .medium))
                        Text("New Session")
                            .font(LitterFont.styled(.subheadline))
                    }
                }
                .foregroundColor(LitterTheme.textOnAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(LitterTheme.accent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .disabled(isStartingNewSession)
            .accessibilityIdentifier("sessions.newSessionButton")
        }
        .padding(16)
    }

    private var serversRow: some View {
        HStack(spacing: 10) {
            let connected = serverManager.connections.values.filter { $0.isConnected }
            let activeThread = serverManager.activeThread
            let activeThreadEphemeralState = activeThread.flatMap { ephemeralStateByThreadKey[$0.key] }
            if connected.isEmpty {
                Image(systemName: "xmark.circle")
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(width: 20)
                Text("Not connected")
                    .font(LitterFont.styled(.footnote))
                    .foregroundColor(LitterTheme.textMuted)
                Spacer()
                Button("Connect") {
                    appState.showServerPicker = true
                }
                .accessibilityIdentifier("sessions.connectButton")
                .font(LitterFont.styled(.caption))
                .foregroundColor(LitterTheme.accent)
            } else {
                Image(systemName: "server.rack")
                    .foregroundColor(LitterTheme.accent)
                    .frame(width: 20)
                Text("\(connected.count) server\(connected.count == 1 ? "" : "s")")
                    .font(LitterFont.styled(.footnote))
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
                Button("Add") {
                    appState.showServerPicker = true
                }
                .accessibilityIdentifier("sessions.addServerButton")
                .font(LitterFont.styled(.caption))
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
                    .disabled(isForkingActiveThread || (activeThreadEphemeralState?.hasTurnActive ?? activeThread.hasTurnActive))
                    .font(LitterFont.styled(.caption))
                    .foregroundColor((activeThreadEphemeralState?.hasTurnActive ?? activeThread.hasTurnActive) ? LitterTheme.textMuted : LitterTheme.accent)
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
                .font(LitterFont.styled(.caption))

            TextField("Search sessions", text: $sessionSearchQuery)
                .font(LitterFont.styled(.footnote))
                .foregroundColor(LitterTheme.textPrimary)
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
                .font(LitterFont.styled(.caption))
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
        .font(LitterFont.styled(.caption))
        .foregroundColor(isActive ? LitterTheme.textOnAccent : LitterTheme.textSecondary)
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
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textPrimary)
                        .lineLimit(1)

                    Text(group.serverHost)
                        .font(LitterFont.styled(.caption2))
                        .foregroundColor(LitterTheme.textMuted)
                        .lineLimit(1)

                    Text(abbreviateHomePath(group.workspacePath))
                        .font(LitterFont.styled(.caption2))
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

    private func sessionList(derived: SessionsDerivedData) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(derived.workspaceSections) { section in
                        if let title = section.title {
                            Text(title)
                                .font(LitterFont.styled(.caption2))
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
                                        ephemeralState: ephemeralStateByThreadKey[thread.key],
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
            renameCurrentTitle = thread.sessionTitle
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
        derived: SessionsDerivedData,
        ephemeralState: SessionsModel.ThreadEphemeralState?,
        depth: Int,
        hasChildren: Bool,
        isCollapsed: Bool,
        onToggleNode: @escaping () -> Void,
        onSelectSession: @escaping () -> Void
    ) -> some View {
        let parent = derived.parentByKey[thread.key]
        let hasTurnActive = ephemeralState?.hasTurnActive ?? thread.hasTurnActive
        let updatedAt = ephemeralState?.updatedAt ?? thread.updatedAt

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
                    if hasTurnActive {
                        PulsingDot().padding(.top, 3)
                    } else {
                        Circle().fill(Color.clear).frame(width: 8, height: 8).padding(.top, 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(thread.sessionTitle)
                                .font(LitterFont.styled(.footnote))
                                .foregroundColor(LitterTheme.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                                .accessibilityIdentifier("sessions.sessionTitle")

                            if thread.isFork {
                                Text("Fork")
                                    .font(LitterFont.styled(.caption2))
                                    .foregroundColor(LitterTheme.textOnAccent)
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

                        HStack(spacing: 4) {
                            Text(relativeDate(updatedAt))
                                .foregroundColor(LitterTheme.textSecondary)
                            if let provider = thread.sessionModelLabel {
                                Text("•")
                                    .foregroundColor(LitterTheme.textMuted)
                                Text(provider)
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                            if let parent {
                                Text("•")
                                    .foregroundColor(LitterTheme.textMuted)
                                Text("from \(parent.sessionTitle)")
                                    .foregroundColor(LitterTheme.textMuted)
                            }
                        }
                        .font(LitterFont.styled(.caption2))
                        .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("sessions.sessionRow")
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

    private func lineageSummary(for thread: ThreadState, derived: SessionsDerivedData) -> some View {
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
                                    Button(sibling.sessionTitle) {
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
                                    Button(child.sessionTitle) {
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
            .font(LitterFont.styled(.caption2))
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
        guard serverManager.activeThreadKey != nil else { return }
        pendingActiveSessionScroll = true
    }

    private func scrollToActiveSessionIfNeeded(derived: SessionsDerivedData, proxy: ScrollViewProxy) {
        guard pendingActiveSessionScroll, let activeKey = serverManager.activeThreadKey else { return }

        guard let activeThread = derived.filteredThreads.first(where: { $0.key == activeKey }) else {
            pendingActiveSessionScroll = false
            return
        }

        let activeWorkspaceGroupID = derived.workspaceGroupIDByThreadKey[activeThread.key] ?? workspaceGroupID(for: activeThread)
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

    private func ancestorThreadKeys(for key: ThreadKey, derived: SessionsDerivedData) -> [ThreadKey] {
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

    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    private func loadSessionsIfNeeded(force: Bool = false) async {
        guard autoLoadSessions else { return }
        guard force || !hasLoadedInitialSessions else { return }
        await loadSessions()
    }

    private func loadSessions() async {
        let signpostID = OSSignpostID(log: sessionsScreenSignpostLog)
        os_signpost(.begin, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID)
        defer { os_signpost(.end, log: sessionsScreenSignpostLog, name: "LoadSessions", signpostID: signpostID) }

        guard serverManager.hasAnyConnection else {
            isLoading = false
            return
        }
        isLoading = true
        await serverManager.refreshAllSessions()
        hasLoadedInitialSessions = true
        isLoading = false
    }

    private func resumeSession(_ thread: ThreadState) async {
        guard resumingKey == nil else { return }
        resumingKey = thread.key
        sessionActionErrorMessage = nil
        await conversationWarmup.prewarmIfNeeded()
        workDir = thread.cwd
        appState.currentCwd = thread.cwd
        let opened = await serverManager.viewThread(
            thread.key,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        resumingKey = nil
        guard opened else {
            if let selectedThread = serverManager.threads[thread.key],
               case .error(let message) = selectedThread.status {
                sessionActionErrorMessage = message
            } else {
                sessionActionErrorMessage = "Failed to open conversation."
            }
            return
        }
        onOpenConversation(thread.key)
    }

    private func startNewSession(serverId: String, cwd: String) async {
        guard !isStartingNewSession else { return }
        isStartingNewSession = true
        defer { isStartingNewSession = false }
        sessionActionErrorMessage = nil
        await conversationWarmup.prewarmIfNeeded()
        workDir = cwd
        appState.currentCwd = cwd
        let model = appState.selectedModel.isEmpty ? nil : appState.selectedModel
        let startedKey = try? await serverManager.startThread(
            serverId: serverId,
            cwd: cwd,
            model: model,
            approvalPolicy: appState.approvalPolicy,
            sandboxMode: appState.sandboxMode
        )
        if let startedKey {
            onOpenConversation(startedKey)
            _ = RecentDirectoryStore.shared.record(path: cwd, for: serverId)
        } else {
            sessionActionErrorMessage = "Failed to start a new session."
        }
    }

    private func forkThread(_ thread: ThreadState) async {
        guard !isForkingActiveThread else { return }
        isForkingActiveThread = true
        defer { isForkingActiveThread = false }
        do {
            let nextKey = try await serverManager.forkThread(
                thread.key,
                cwd: thread.cwd,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
            if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
            onOpenConversation(nextKey)
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

private struct SessionTreeRow: Identifiable {
    let thread: ThreadState
    let depth: Int
    let hasChildren: Bool

    var id: ThreadKey { thread.key }
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

#if DEBUG
#Preview("Sessions Screen") {
    LitterPreviewScene(
        serverManager: LitterPreviewData.makeSidebarManager(),
        appState: LitterPreviewData.makeAppState()
    ) {
        NavigationStack {
            SessionsScreen(autoLoadSessions: false, onOpenConversation: { _ in })
        }
    }
}
#endif
