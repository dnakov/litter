import SwiftUI

struct HomeDashboardView: View {
    let recentSessions: [HomeDashboardRecentSession]
    let allSessions: [HomeDashboardRecentSession]
    let pinnedThreadKeys: [SavedThreadsStore.PinnedKey]
    let connectedServers: [HomeDashboardServer]
    let projects: [AppProject]
    let selectedServerId: String?
    let selectedProject: AppProject?
    let openingRecentSessionKey: ThreadKey?
    let onOpenRecentSession: @MainActor (HomeDashboardRecentSession) async -> Void
    let onSelectServer: (HomeDashboardServer) -> Void
    let onAddServer: () -> Void
    let onOpenProjectPicker: () -> Void
    let onThreadCreated: (ThreadKey) -> Void
    let onShowSettings: () -> Void
    let onPinThread: (ThreadKey) -> Void
    let onUnpinThread: (ThreadKey) -> Void
    let onHideThread: (ThreadKey) -> Void
    /// Hydrate a single thread (load full conversation items). Dashboard
    /// orchestrates the parallel calls and tracks per-row state so the left
    /// indicator can reflect it.
    var onHydrateThread: ((ThreadKey) async -> Void)? = nil
    var onDeleteThread: ((ThreadKey) async -> Void)? = nil
    var onReconnectServer: ((HomeDashboardServer) -> Void)? = nil
    var onDisconnectServer: ((String) -> Void)? = nil
    var onRenameServer: ((String, String) -> Void)? = nil
    var onOpenRecording: ((URL) -> Void)? = nil
    /// Fires when the user commits a quick reply from the swipe action.
    /// Caller should call `appModel.startTurn` against the thread.
    var onSendReply: (@MainActor (ThreadKey, String) async -> Void)? = nil
    /// Cancels the active turn on the given thread. Caller looks up the
    /// thread's `activeTurnId` and calls `appModel.client.interruptTurn`.
    var onCancelThread: (@MainActor (ThreadKey) async -> Void)? = nil

    @State private var deleteTargetThread: HomeDashboardRecentSession?
    @State private var replyTargetThread: HomeDashboardRecentSession?
    /// Tracks threads the user just cancelled so their status dot can show
    /// red until the snapshot confirms the turn is no longer active.
    @State private var cancellingKeys: Set<String> = []
    @AppStorage("homeZoomLevel") private var zoomLevel = 2
    /// Direction of the toolbar zoom toggle: +1 walks up, -1 walks down.
    /// Flips at the 1/4 boundaries so the button bounces 1→2→3→4→3→2→1.
    @State private var zoomDirection: Int = 1
    /// Shared spring for zoom transitions — tuned to feel like Clear's
    /// elastic row expand/collapse. Used by the toolbar button, pinch
    /// gesture, the outer list-level animation, and each row's internal
    /// height tween + drawer transitions.
    static let zoomSpring = Animation.spring(response: 0.42, dampingFraction: 0.78)
    @State private var pinchBaseZoom: Int?
    @State private var isPinching = false
    @State private var renameServerTarget: HomeDashboardServer?
    @State private var renameServerText = ""
    @State private var inputMode: HomeInputMode = .collapsed
    @State private var searchQuery = ""
    @State private var hydratingKeys: Set<String> = []
    @State private var hasLoadedThreadListing = false
    @State private var isLoadingThreadListing = false

    var onLoadAllThreads: (() async -> Void)? = nil

    private var isSearchExpanded: Bool { inputMode == .search }
    /// Keys we've already kicked off hydration for, so we don't re-request
    /// when the snapshot refreshes.
    @State private var requestedHydrationKeys: Set<String> = []

    private func hydrationId(_ key: ThreadKey) -> String {
        "\(key.serverId)/\(key.threadId)"
    }

    private func autoHydrateIfNeeded() {
        guard let onHydrateThread else { return }
        for session in visibleSessions where session.stats == nil {
            let id = hydrationId(session.key)
            guard !requestedHydrationKeys.contains(id) else { continue }
            requestedHydrationKeys.insert(id)
            hydratingKeys.insert(id)
            Task {
                await onHydrateThread(session.key)
                await MainActor.run {
                    hydratingKeys.remove(id)
                }
            }
        }
    }

    private var visibleSessions: [HomeDashboardRecentSession] {
        let serverId = selectedProject?.serverId ?? selectedServerId
        guard let serverId, !serverId.isEmpty else { return recentSessions }
        return recentSessions.filter { $0.serverId == serverId }
    }

    private var zoomIcon: String {
        switch zoomLevel {
        case 1: return "list.bullet"
        case 2: return "list.dash"
        case 3: return "list.bullet.rectangle"
        default: return "list.bullet.rectangle.fill"
        }
    }

    var body: some View {
        canvas
            .task { await TipJarStore.shared.loadProducts() }
            .onAppear { autoHydrateIfNeeded() }
            .onChange(of: visibleSessions.map { hydrationId($0.key) }) { _, _ in
                autoHydrateIfNeeded()
            }
            // Clear a cancelled key once the snapshot says the turn is
            // actually gone. Gives the dot a brief red period while the
            // cancel is in flight, then reverts to normal indicator logic.
            .onChange(of: visibleSessions.map { "\(hydrationId($0.key)):\($0.hasTurnActive)" }) { _, _ in
                let stillActive = Set(
                    visibleSessions
                        .filter { $0.hasTurnActive }
                        .map { hydrationId($0.key) }
                )
                cancellingKeys.formIntersection(stillActive)
            }
            .task(id: isSearchExpanded) {
                guard isSearchExpanded, !hasLoadedThreadListing, let onLoadAllThreads else { return }
                isLoadingThreadListing = true
                await onLoadAllThreads()
                hasLoadedThreadListing = true
                isLoadingThreadListing = false
            }
            .background(LitterTheme.backgroundGradient.ignoresSafeArea())
            .alert("Delete Session?", isPresented: Binding(
                get: { deleteTargetThread != nil },
                set: { if !$0 { deleteTargetThread = nil } }
            )) {
                Button("Cancel", role: .cancel) { deleteTargetThread = nil }
                Button("Delete", role: .destructive) {
                    if let thread = deleteTargetThread {
                        Task { await onDeleteThread?(thread.key) }
                    }
                    deleteTargetThread = nil
                }
            } message: {
                Text("This will permanently delete \"\(deleteTargetThread?.sessionTitle ?? "this session")\".")
            }
            .alert("Rename server", isPresented: Binding(
                get: { renameServerTarget != nil },
                set: { if !$0 { renameServerTarget = nil } }
            )) {
                TextField("Server name", text: $renameServerText)
                Button("Cancel", role: .cancel) { renameServerTarget = nil }
                Button("Save") {
                    if let server = renameServerTarget {
                        let trimmed = renameServerText.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty {
                            onRenameServer?(server.id, trimmed)
                        }
                    }
                    renameServerTarget = nil
                }
            }
            .sheet(item: $replyTargetThread) { thread in
                QuickReplySheet(
                    thread: thread,
                    onSend: { key, text in
                        await onSendReply?(key, text)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onShowSettings) {
                        Image(systemName: "gearshape")
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 4) {
                        SupporterKittyBadges(tierIndices: 0..<2)
                        AnimatedLogo(size: 64)
                        SupporterKittyBadges(tierIndices: 2..<4)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        var next = zoomLevel + zoomDirection
                        if next > 4 {
                            zoomDirection = -1
                            next = zoomLevel + zoomDirection
                        } else if next < 1 {
                            zoomDirection = 1
                            next = zoomLevel + zoomDirection
                        }
                        withAnimation(Self.zoomSpring) {
                            zoomLevel = next
                        }
                    } label: {
                        Image(systemName: zoomIcon)
                            .foregroundColor(LitterTheme.textSecondary)
                    }
                }
            }
    }

    private var canvas: some View {
        ZStack {
            // When search is open, replace the list entirely so we're not
            // fighting two scroll containers. When it's closed, the overlay
            // branch returns nothing and can't intercept scroll gestures.
            if isSearchExpanded {
                ZStack(alignment: .top) {
                    LitterTheme.backgroundGradient.ignoresSafeArea()
                    ThreadSearchResultsView(
                        sessions: allSessions,
                        pinnedThreadKeys: Set(pinnedThreadKeys),
                        query: searchQuery,
                        isLoading: isLoadingThreadListing && allSessions.isEmpty,
                        onAdd: { session in
                            onPinThread(session.key)
                            withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                                inputMode = .collapsed
                            }
                            searchQuery = ""
                        },
                        onRemove: { session in
                            onUnpinThread(session.key)
                        },
                        contentInsets: EdgeInsets(top: 48, leading: 0, bottom: 140, trailing: 0)
                    )
                }
                .transition(.opacity)
            } else {
                sessionsList
            }
        }
        .overlay(alignment: .top) { topChrome }
        .overlay(alignment: .bottom) { bottomChrome }
    }

    // Search results are rendered directly in `canvas` as an inline
    // replacement for the sessions list when `isSearchExpanded` is true.

    private var topChrome: some View {
        ServerPillRow(
            servers: connectedServers,
            selectedServerId: selectedProject?.serverId ?? selectedServerId,
            onTap: onSelectServer,
            onReconnect: { server in onReconnectServer?(server) },
            onRename: { server in
                renameServerText = server.displayName
                renameServerTarget = server
            },
            onRemove: { server in onDisconnectServer?(server.id) },
            onAdd: onAddServer
        )
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                colors: LitterTheme.headerScrim,
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.bottom, -30)
            .ignoresSafeArea(.container, edges: .top)
            .allowsHitTesting(false)
        )
    }

    private var bottomChrome: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if inputMode == .composer {
                HStack(spacing: 8) {
                    Spacer()
                    HomeModelChip(
                        serverId: selectedProject?.serverId ?? selectedServerId,
                        disabled: (selectedProject?.serverId ?? selectedServerId) == nil
                    )
                    ProjectChip(
                        project: selectedProject,
                        disabled: connectedServers.isEmpty,
                        onTap: onOpenProjectPicker
                    )
                }
                .padding(.horizontal, 14)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HomeBottomBar(
                mode: $inputMode,
                searchQuery: $searchQuery,
                project: selectedProject,
                onThreadCreated: onThreadCreated
            )
        }
        .padding(.bottom, 4)
        .background(
            LinearGradient(
                colors: Array(LitterTheme.headerScrim.reversed()),
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(.top, -30)
            .ignoresSafeArea(.container, edges: .bottom)
            .allowsHitTesting(false)
        )
    }

    private var sessionsList: some View {
        List {
            if visibleSessions.isEmpty {
                emptyState
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            } else {
                ForEach(visibleSessions) { session in
                    sessionRow(session)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.top, 48, for: .scrollContent)
        .contentMargins(.bottom, 140, for: .scrollContent)
        .animation(Self.zoomSpring, value: zoomLevel)
        .frame(maxHeight: .infinity)
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    isPinching = true
                    if pinchBaseZoom == nil { pinchBaseZoom = zoomLevel }
                    guard let base = pinchBaseZoom else { return }
                    let delta = Int(round((value.magnification - 1.0) / 0.4))
                    let newLevel = max(1, min(4, base + delta))
                    if newLevel != zoomLevel {
                        withAnimation(Self.zoomSpring) {
                            zoomLevel = newLevel
                        }
                    }
                }
                .onEnded { value in
                    if let base = pinchBaseZoom {
                        let delta = Int(round((value.magnification - 1.0) / 0.4))
                        let newLevel = max(1, min(4, base + delta))
                        if newLevel != zoomLevel {
                            withAnimation(Self.zoomSpring) {
                                zoomLevel = newLevel
                            }
                        }
                    }
                    pinchBaseZoom = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isPinching = false
                    }
                }
        )
    }



    @ViewBuilder
    private func sessionRow(_ session: HomeDashboardRecentSession) -> some View {
        let pinned = pinnedThreadKeys.contains(SavedThreadsStore.PinnedKey(threadKey: session.key))
        SessionCanvasLine(
            session: session,
            isOpening: openingRecentSessionKey == session.key,
            isHydrating: hydratingKeys.contains(hydrationId(session.key)),
            isCancelling: cancellingKeys.contains(hydrationId(session.key)),
            zoomLevel: zoomLevel
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isPinching, openingRecentSessionKey == nil else { return }
            Task { await onOpenRecentSession(session) }
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                replyTargetThread = session
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left.fill")
            }
            .tint(LitterTheme.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button {
                onHideThread(session.key)
            } label: {
                Label("Hide", systemImage: "eye.slash.fill")
            }
            .tint(LitterTheme.danger)
        }
        .contextMenu {
            Button {
                replyTargetThread = session
            } label: {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
            }
            if session.hasTurnActive {
                Button(role: .destructive) {
                    cancellingKeys.insert(hydrationId(session.key))
                    Task { await onCancelThread?(session.key) }
                } label: {
                    Label("Cancel Turn", systemImage: "stop.circle")
                }
            }
            Button {
                if pinned {
                    onUnpinThread(session.key)
                } else {
                    onPinThread(session.key)
                }
            } label: {
                Label(
                    pinned ? "Remove from Home" : "Pin to Home",
                    systemImage: pinned ? "minus.circle" : "pin"
                )
            }
            Button {
                onHideThread(session.key)
            } label: {
                Label("Hide from Home", systemImage: "eye.slash")
            }
            Button(role: .destructive) {
                deleteTargetThread = session
            } label: {
                Label("Delete Session", systemImage: "trash")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("No sessions yet")
                .litterFont(.subheadline, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)
            Text(connectedServers.isEmpty
                 ? "Connect a server to start your first session."
                 : "Pick a project and send a message to start one.")
                .litterFont(.caption)
                .foregroundStyle(LitterTheme.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }
}

// MARK: - Session Canvas Layout

private enum SessionCanvasLayout {
    static let horizontalPadding: CGFloat = 14
    static let markerWidth: CGFloat = 14
    static let markerSpacing: CGFloat = 8
}

/// One row in the home zoom-4 tool log. `exploration` collapses multiple
/// consecutive read/search/listFiles commands into a single summary line
/// (matching the conversation view's grouping behavior); `tool` is a
/// single-line entry for any other kind of tool call.
private enum HomeToolRow: Identifiable {
    case exploration(id: String, summary: String)
    case tool(id: String, icon: String, detail: String)

    var id: String {
        switch self {
        case .exploration(let id, _): return id
        case .tool(let id, _, _): return id
        }
    }

    var icon: String {
        switch self {
        case .exploration: return "⌕"
        case .tool(_, let icon, _): return icon
        }
    }

    var detail: String {
        switch self {
        case .exploration(_, let summary): return summary
        case .tool(_, _, let detail): return detail
        }
    }
}


// MARK: - Session Canvas Line

private struct SessionCanvasLine: View {
    let session: HomeDashboardRecentSession
    let isOpening: Bool
    let isHydrating: Bool
    let isCancelling: Bool
    let zoomLevel: Int

    @Environment(AppModel.self) private var appModel

    private var isActive: Bool { session.hasTurnActive }
    private var isHydrated: Bool { session.stats != nil }
    private var timeAgo: String { relativeDate(Int64(session.updatedAt.timeIntervalSince1970)) }
    private var s: AppConversationStats? { session.stats }
    private var toolCallCount: UInt32 { s?.toolCallCount ?? 0 }
    private var turnCount: UInt32 { s?.turnCount ?? 0 }

    /// Full hydrated item list for this thread (empty if the thread hasn't
    /// been hydrated yet). Used for richer zoom-4 displays that need to see
    /// item types directly — e.g. grouping exploration commands.
    private var hydratedItems: [ConversationItem] {
        appModel.snapshot?.threadSnapshot(for: session.key)?
            .hydratedConversationItems.map(\.conversationItem) ?? []
    }

    /// Last *non-empty* assistant message on this thread. When a new turn
    /// starts the latest assistant item is created with empty text and
    /// fills in as deltas arrive — returning it directly would blank the
    /// row mid-turn. Walking back to the last non-empty block keeps the
    /// previous response visible until the new one actually has content,
    /// at which point `id` changes and the render layer can crossfade.
    private var displayedAssistantMessage: (id: String, text: String)? {
        for item in hydratedItems.reversed() {
            if item.isAssistantItem {
                let text = (item.assistantText ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    return (id: item.id, text: item.assistantText ?? "")
                }
            }
        }
        return nil
    }

    /// True only when the most recent tool-capable item is actually
    /// in-progress. Used to gate the zoom-2 tool-activity label + pulsing
    /// dots so they appear only during real tool execution, not every
    /// time the assistant is thinking/streaming.
    private var isToolCallRunning: Bool {
        for item in hydratedItems.reversed() {
            switch item.content {
            case .commandExecution(let data):
                return data.isInProgress
            case .mcpToolCall(let data):
                return data.isInProgress
            case .dynamicToolCall(let data):
                return data.isInProgress
            case .fileChange(let data):
                return data.status == .pending || data.status == .inProgress
            default:
                continue
            }
        }
        return false
    }

    /// Start/end of the most recent turn, derived from item timestamps.
    /// `end == nil` signals an in-progress turn — the chip drives a live
    /// ticker. When the turn completes, `end` is the max item timestamp
    /// in that turn (which the server updates as items finalize), so the
    /// displayed duration is always calculated from data rather than
    /// captured in view state.
    private var lastTurnBounds: (start: Date, end: Date?)? {
        let items = hydratedItems
        guard let lastTurnId = items.reversed().compactMap(\.sourceTurnId).first else {
            return nil
        }
        let turnItems = items.filter { $0.sourceTurnId == lastTurnId }
        guard let start = turnItems.map(\.timestamp).min() else { return nil }
        if isActive { return (start: start, end: nil) }
        let end = turnItems.map(\.timestamp).max() ?? start
        return (start: start, end: end)
    }

    // ────────────────────────────────────────────────────
    // Zoom levels — each must feel distinct:
    //
    //  1  SCAN     title only. Max density for scanning.
    //  2  GLANCE   title + meta line (activity or summary). Identify sessions.
    //  3  READ     title + activity + server/model + tool log. Understand what happened.
    //  4  DEEP     multi-line title + full response preview + tool log expanded + cwd.
    //
    // Active sessions always show activity status. Time only shows where it adds info
    // (zoom 2 summary, zoom 3+ right column). Never duplicated.
    // ────────────────────────────────────────────────────

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Group {
                if isOpening {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(LitterTheme.accent)
                } else {
                    statusIndicator
                }
            }
            .frame(width: SessionCanvasLayout.markerWidth, height: 16)
            .padding(.trailing, SessionCanvasLayout.markerSpacing)
            .padding(.top, zoomLevel == 1 ? 0 : 2)

            VStack(alignment: .leading, spacing: 0) {
                // Title — always solo on its own line at every zoom level.
                FormattedText(text: session.sessionTitle, lineLimit: zoomLevel >= 4 ? 4 : 1)
                    .modifier(MarkdownMatchedTitleFont())
                    .foregroundStyle(isActive ? LitterTheme.accent : LitterTheme.textPrimary)
                    .modifier(SessionShimmerEffect(active: isActive))
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Detail below — gets full width. As zoom grows, additional
                // rows are revealed by the container's layout animation.
                // Inner VStack is pinned to full width so removals collapse
                // vertically only — otherwise the container sizes to the
                // widest child and short rows visually shrink to the left.
                VStack(alignment: .leading, spacing: 0) {
                    if zoomLevel == 2 {
                        metaLine
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                    if zoomLevel >= 3 {
                        modelBadgeLine
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                    if zoomLevel >= 3 {
                        userMessageLine
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                    if zoomLevel >= 3 {
                        toolLog(maxEntries: zoomLevel >= 4 ? 3 : 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                    if zoomLevel >= 3 {
                        responsePreview
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                    if zoomLevel == 4 && !session.cwd.isEmpty {
                        Text(session.cwd)
                            .litterMonoFont(size: 10, weight: .regular)
                            .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
                            .lineLimit(2)
                            .padding(.top, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .transition(Self.drawerTransition)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SessionCanvasLayout.horizontalPadding)
        .padding(.vertical, [3, 6, 10, 12][min(zoomLevel - 1, 3)])
        .background(alignment: .leading) {
            if isActive {
                LitterTheme.accent.opacity(0.3).frame(width: 2)
            }
        }
        .background(isActive ? LitterTheme.accent.opacity(0.02) : Color.clear)
        .contentShape(Rectangle())
        .clipped()
        .animation(HomeDashboardView.zoomSpring, value: zoomLevel)
        .animation(.easeInOut(duration: 0.25), value: isActive)
        .accessibilityIdentifier("home.recentSessionCard")
    }

    /// Pure crossfade. The container's height spring already provides the
    /// motion; any translation here fights the expand direction (e.g. on
    /// 3→4 inserts the content would slide toward the top while the drawer
    /// is opening downward). Insertion is delayed slightly so the container
    /// starts opening before content appears, removal is quick so content
    /// clears while the container closes.
    private static let drawerTransition: AnyTransition = .asymmetric(
        insertion: .opacity.animation(.easeInOut(duration: 0.22).delay(0.06)),
        removal: .opacity.animation(.easeOut(duration: 0.10))
    )

    // MARK: - Zoom 2: meta line

    private var metaLine: some View {
        HStack(spacing: 4) {
            Text(timeAgo)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
            // Only show the tool label + pulsing dots when a tool call
            // is actually executing. During pure LLM thinking/streaming
            // we fall through to the server + workspace metadata, same
            // as when the turn is idle.
            if isActive && isToolCallRunning {
                Text("\u{00b7}")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                toolActivityLabel
                SessionPulsingDots()
                statChips
            } else {
                Text("\u{00b7}")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                Text(session.serverDisplayName)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.7))
                if let workspace = HomeDashboardSupport.workspaceLabel(for: session.cwd) {
                    Text("\u{00b7}")
                        .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text(workspace)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                }
                statChips
            }
        }
        .litterMonoFont(size: 10, weight: .regular)
        .lineLimit(1)
        .padding(.top, 2)
    }

    /// Inline stat chips: tool calls, turns, context %
    @ViewBuilder
    private var statChips: some View {
        if toolCallCount > 0 || turnCount > 0 {
            Text("\u{00b7}")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
        }
        if toolCallCount > 0 {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .litterFont(size: 8)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            Text("\(toolCallCount)")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
        }
        if turnCount > 0 {
            Image(systemName: "arrow.turn.down.right")
                .litterFont(size: 8)
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            Text("\(turnCount)")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
        }
        if let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 {
            let pct = Int((Double(tu.totalTokens) / Double(window)) * 100)
            Text("\u{00b7}")
                .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
            Text("\(pct)%")
                .foregroundStyle(pct > 80 ? LitterTheme.warning.opacity(0.8) : LitterTheme.textMuted.opacity(0.8))
        }
    }

    @ViewBuilder
    private var toolActivityLabel: some View {
        if let toolLabel = session.lastToolLabel {
            let parts = toolLabel.split(separator: " ", maxSplits: 1)
            let name = String(parts.first ?? "")
            Text(toolIconForName(name))
                .foregroundStyle(LitterTheme.accent)
            if parts.count > 1 {
                Text(String(parts.last ?? ""))
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        } else {
            Text("thinking")
                .foregroundStyle(LitterTheme.accent)
        }
    }

    // MARK: - Zoom 3+: model + badges (no workspace — already shown)

    private var modelBadgeLine: some View {
        HStack(spacing: 4) {
            // Left group — the only text that might need to truncate when
            // the row is tight. Keeping `.lineLimit(1)` scoped to this
            // group prevents it from propagating into the chip HStacks on
            // the right and chopping short numerics to ellipses.
            HStack(spacing: 4) {
                Text(timeAgo)
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.8))
                Text("\u{00b7}")
                    .foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                Image(systemName: "server.rack")
                    .litterFont(size: 8)
                    .foregroundStyle(LitterTheme.accent.opacity(0.5))
                Text(session.serverDisplayName)
                    .foregroundStyle(LitterTheme.accent.opacity(0.6))
                let m = session.model.trimmingCharacters(in: .whitespacesAndNewlines)
                if !m.isEmpty {
                    Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text(m)
                        .foregroundStyle(LitterTheme.textSecondary.opacity(0.7))
                }
                if session.isFork {
                    Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text("fork")
                        .foregroundStyle(LitterTheme.warning.opacity(0.8))
                }
                if session.isSubagent, let agent = session.agentLabel {
                    Text("\u{00b7}").foregroundStyle(LitterTheme.textMuted.opacity(0.5))
                    Text(agent)
                        .foregroundStyle(LitterTheme.accent.opacity(0.6))
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)

            Spacer(minLength: 6)
            inlineStats
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
        .litterMonoFont(size: 10, weight: .regular)
        .padding(.top, 1)
    }

    /// Compact stat chips appended to the right end of `modelBadgeLine` so
    /// they share a line instead of adding new rows to the row height.
    @ViewBuilder
    private var inlineStats: some View {
        HStack(spacing: 6) {
            if turnCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "arrow.turn.down.right")
                        .litterFont(size: 8)
                    Text("\(turnCount)")
                }
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            }
            if toolCallCount > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left.forwardslash.chevron.right")
                        .litterFont(size: 8)
                    Text("\(toolCallCount)")
                }
                .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
            }
            if let stats = s, stats.diffAdditions > 0 || stats.diffDeletions > 0 {
                HStack(spacing: 2) {
                    Text("+\(stats.diffAdditions)")
                        .foregroundStyle(LitterTheme.accent.opacity(0.7))
                    Text("-\(stats.diffDeletions)")
                        .foregroundStyle(LitterTheme.danger.opacity(0.6))
                }
            }
            if let bounds = lastTurnBounds {
                TurnStopwatchChip(start: bounds.start, end: bounds.end)
            }
            if let tu = session.tokenUsage, let window = tu.contextWindow, window > 0 {
                let pct = Int((Double(tu.totalTokens) / Double(window)) * 100)
                Text("\(pct)%")
                    .foregroundStyle(pct > 80 ? LitterTheme.warning.opacity(0.8) : LitterTheme.textMuted.opacity(0.7))
            }
        }
    }

    // MARK: - Zoom 3+: last user message (quoted, single line)

    @ViewBuilder
    private var userMessageLine: some View {
        let message = (session.lastUserMessage ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let title = session.sessionTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty && message != title {
            HStack(alignment: .top, spacing: 6) {
                Text(">")
                    .foregroundStyle(LitterTheme.accent.opacity(0.7))
                FormattedText(text: message, lineLimit: 1)
                    .foregroundStyle(LitterTheme.textSecondary.opacity(0.9))
            }
            // Match the conversation view's user-message size
            // (`UserBubble` uses `.litterFont(size: conversationBodyPointSize)`).
            // Same regular (non-mono) font too, for visual parity.
            .litterFont(size: LitterFont.conversationBodyPointSize)
            .padding(.top, 3)
        }
    }

    // MARK: - Zoom 3+: tool call log

    @ViewBuilder
    private func toolLog(maxEntries: Int) -> some View {
        // Groups consecutive exploration commands (reads/searches/listings)
        // into one summary line, same as the conversation view, but always
        // single-line (no expand/collapse). The Rust-side `recentToolLog`
        // is derived from the exact same hydrated items, so we don't need
        // a separate fallback.
        let rows = hydratedToolRows(limit: maxEntries)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(rows) { row in
                    toolRowView(row)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 2)
        }
    }

    @ViewBuilder
    private func toolRowView(_ row: HomeToolRow) -> some View {
        HStack(spacing: 8) {
            toolIconView(row.icon)
                .foregroundStyle(LitterTheme.accent.opacity(0.6))
                .frame(minWidth: 20, alignment: .leading)
            Text(row.detail)
                .foregroundStyle(LitterTheme.textSecondary.opacity(0.8))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        // Match the conversation view's tool-call summary size —
        // `ToolCallCardView` uses `.litterFont(size: contentFontSize)` =
        // `LitterFont.conversationBodyPointSize` — and a regular (non-mono)
        // font so titles/messages/tools all read at the same scale.
        .litterFont(size: LitterFont.conversationBodyPointSize)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A couple of tool icons read better as SF Symbols (a "computer" glyph
    /// for MCP / external tool calls) than as a text abbreviation. Text
    /// glyphs (`$`, `✎`, `·`, `⌕`) render directly. The 12pt semibold
    /// matches `ToolCallCardView`'s icon in the conversation view.
    @ViewBuilder
    private func toolIconView(_ icon: String) -> some View {
        switch icon {
        case "mcp":
            Image(systemName: "desktopcomputer")
                .litterFont(size: 12, weight: .semibold)
        case "tool":
            Image(systemName: "wrench.and.screwdriver")
                .litterFont(size: 12, weight: .semibold)
        default:
            Text(icon)
                .litterFont(size: 12, weight: .semibold)
        }
    }

    /// Derive a grouped tool log from `hydratedItems`. Consecutive
    /// exploration command items collapse into a single summary row
    /// (e.g. `⌕ Explored 3 files, 2 searches`); everything else becomes a
    /// standalone single-line row. Returns the *last* `limit` rows.
    private func hydratedToolRows(limit: Int) -> [HomeToolRow] {
        let items = hydratedItems
        guard !items.isEmpty else { return [] }
        var rows: [HomeToolRow] = []
        var buffer: [ConversationItem] = []

        func flushExploration() {
            guard !buffer.isEmpty else { return }
            let anyInProgress = buffer.contains { item in
                if case .commandExecution(let data) = item.content {
                    return data.isInProgress
                }
                return false
            }
            let prefix = anyInProgress ? "Exploring" : "Explored"
            let summary = explorationSummary(for: buffer, prefix: prefix)
            let seed = buffer.first?.id ?? UUID().uuidString
            rows.append(.exploration(id: "exploration-\(seed)", summary: summary))
            buffer.removeAll(keepingCapacity: true)
        }

        for item in items {
            if item.isExplorationCommandItem {
                buffer.append(item)
                continue
            }
            flushExploration()
            if let row = toolRow(for: item) {
                rows.append(row)
            }
        }
        flushExploration()

        if rows.count <= limit { return rows }
        return Array(rows.suffix(limit))
    }

    private func toolRow(for item: ConversationItem) -> HomeToolRow? {
        switch item.content {
        case .commandExecution(let data):
            let cmd = data.command.split(separator: "\n").first.map(String.init) ?? data.command
            return .tool(id: "cmd-\(item.id)", icon: "$", detail: cmd.trimmingCharacters(in: .whitespaces))
        case .fileChange(let data):
            let paths = data.changes.prefix(3).map { ($0.path as NSString).lastPathComponent }
            let tail = data.changes.count > 3 ? " +\(data.changes.count - 3)" : ""
            return .tool(id: "edit-\(item.id)", icon: "✎", detail: paths.joined(separator: ", ") + tail)
        case .mcpToolCall(let data):
            return .tool(id: "mcp-\(item.id)", icon: "mcp", detail: data.tool)
        case .dynamicToolCall(let data):
            return .tool(id: "dyn-\(item.id)", icon: "tool", detail: data.tool)
        case .webSearch(let data):
            return .tool(id: "web-\(item.id)", icon: "⌕", detail: data.query ?? "search")
        default:
            return nil
        }
    }

    private func explorationSummary(for items: [ConversationItem], prefix: String) -> String {
        var readCount = 0, searchCount = 0, listingCount = 0, fallbackCount = 0
        for item in items {
            guard case .commandExecution(let data) = item.content else { continue }
            if data.actions.isEmpty {
                fallbackCount += 1
                continue
            }
            for action in data.actions {
                switch action.kind {
                case .read: readCount += 1
                case .search: searchCount += 1
                case .listFiles: listingCount += 1
                case .unknown: fallbackCount += 1
                }
            }
        }
        var parts: [String] = []
        if readCount > 0 { parts.append("\(readCount) \(readCount == 1 ? "file" : "files")") }
        if searchCount > 0 { parts.append("\(searchCount) \(searchCount == 1 ? "search" : "searches")") }
        if listingCount > 0 { parts.append("\(listingCount) \(listingCount == 1 ? "listing" : "listings")") }
        if fallbackCount > 0 { parts.append("\(fallbackCount) \(fallbackCount == 1 ? "step" : "steps")") }
        if parts.isEmpty {
            return "\(prefix) \(items.count) step\(items.count == 1 ? "" : "s")"
        }
        return "\(prefix) \(parts.joined(separator: ", "))"
    }

    /// Map the Rust-derived tool name (`"Bash"`, `"Edit"`, etc.) to the
    /// short single-character/phrase display used in the home list.
    private func toolIconForName(_ name: String) -> String {
        switch name {
        case "Bash": return "$"
        case "Edit": return "✎"
        case "MCP": return "mcp"
        case "Tool": return "tool"
        default: return name
        }
    }

    // MARK: - Zoom 4: last response preview

    @ViewBuilder
    private var responsePreview: some View {
        // Plain markdown — no streaming token-reveal bubble. The reducer
        // piggybacks a fresh session summary on every item change, so the
        // markdown already grows in place as deltas land. We pick the last
        // *non-empty* assistant item so a new turn's empty assistant block
        // doesn't blank the row mid-stream, then crossfade via `.id(blockId)`
        // when a genuinely new block takes over.
        let live = displayedAssistantMessage
        let fallback = (session.lastResponsePreview ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let liveText = (live?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let markdown = !liveText.isEmpty ? (live?.text ?? "") : fallback
        let blockId = live?.id ?? "fallback"
        if markdown.count > 20 {
            // ViewThatFits picks the first child whose natural size fits
            // the proposed container. The container is capped at
            // `responsePreviewMaxHeight`, so:
            //   - Short markdown (natural ≤ cap): the fixed-size rendering
            //     wins, frame shrinks to natural height → no blank space.
            //   - Long markdown (natural > cap): the first child is too
            //     tall, so ViewThatFits falls through to the scroll-based
            //     fallback — scroll is disabled but `defaultScrollAnchor(.bottom)`
            //     keeps the tail visible, and the frame stays at cap.
            // This pattern is the clean SwiftUI answer for "shrink to
            // content OR cap-with-tail-visible"; the earlier
            // `fixedSize + frame(maxHeight:, alignment: .bottom)` combo
            // composed unpredictably with Textual's MarkdownView intrinsic
            // sizing and inflated every row to cap height.
            // Match the conversation view's defaults —
            // `LitterFont.conversationBodyPointSize` × `textScale` — so
            // markdown in the home preview renders at the same size as in
            // the actual conversation.
            let previewMarkdown = LitterMarkdownView(
                markdown: markdown,
                selectionEnabled: false
            )
            ViewThatFits(in: .vertical) {
                previewMarkdown
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView(.vertical, showsIndicators: false) {
                    previewMarkdown
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .scrollDisabled(true)
            }
            .id(blockId)
            // Bundle the animation into the transition itself so the
            // crossfade fires on every `.id` change without relying on an
            // external `.animation(value:)` context — that combo can miss
            // animations when SwiftUI doesn't see a clear state-change
            // trigger across the id swap.
            .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            .frame(maxHeight: responsePreviewMaxHeight)
            .clipped()
            .mask(
                LinearGradient(
                    gradient: Gradient(stops: [
                        .init(color: .black.opacity(0.55), location: 0),
                        .init(color: .black.opacity(0.85), location: 0.10),
                        .init(color: .black, location: 0.22)
                    ]),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .padding(.top, 4)
        }
    }

    /// Screen-height-relative cap on the response preview. Zoom 3 gets a
    /// tight 25% so the row stays scan-able in a dense list; zoom 4 gets
    /// 50% for a fuller read. Computed at render time so it adapts to
    /// device size + orientation.
    private var responsePreviewMaxHeight: CGFloat {
        let screenHeight = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.screen.bounds.height ?? 800
        return screenHeight * (zoomLevel >= 4 ? 0.5 : 0.25)
    }


    // MARK: - Status Indicator

    private var dotState: StatusDotState {
        if isCancelling { return .error }
        if isActive { return .active }
        if isHydrating { return .pending }
        if isHydrated { return .ok }
        return .idle
    }

    private var statusIndicator: some View {
        StatusDot(state: dotState)
    }
}

// MARK: - Canvas Animation Components

/// Stopwatch chip rendered at the right of the modelBadgeLine. When
/// `end` is nil the turn is live and a `TimelineView` drives a 1 Hz
/// re-eval. When `end` is provided, the chip is static and shows the
/// calculated turn duration (`end - start`) — no in-memory freeze.
private struct TurnStopwatchChip: View {
    let start: Date
    let end: Date?

    var body: some View {
        if let end {
            chip(seconds: max(0, end.timeIntervalSince(start)))
        } else {
            TimelineView(.periodic(from: .now, by: 1.0)) { context in
                chip(seconds: max(0, context.date.timeIntervalSince(start)))
            }
        }
    }

    @ViewBuilder
    private func chip(seconds: TimeInterval) -> some View {
        HStack(spacing: 2) {
            Image(systemName: "stopwatch")
                .litterFont(size: 8)
            Text(Self.format(seconds))
        }
        .foregroundStyle(LitterTheme.textMuted.opacity(0.7))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let mins = total / 60
        let secs = total % 60
        return secs == 0 ? "\(mins)m" : "\(mins)m\(secs)s"
    }
}

private struct SessionPulsingDots: View {
    @State private var phase = 0

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(LitterTheme.accent)
                    .frame(width: 3, height: 3)
                    .opacity(phase == i ? 1.0 : 0.25)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                withAnimation(.easeInOut(duration: 0.15)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

/// Renders the task title at the same size the conversation view uses for
/// message bodies (`LitterFont.conversationBodyPointSize × textScale`) so
/// titles and user/assistant messages in the home list match the sizes you
/// see inside a conversation. Kept medium-weight (rather than bold) so the
/// title reads as a row heading without visually dominating the response.
private struct MarkdownMatchedTitleFont: ViewModifier {
    @Environment(\.textScale) private var textScale
    func body(content: Content) -> some View {
        content
            .font(.custom(
                LitterFont.markdownFontName,
                size: LitterFont.conversationBodyPointSize * textScale
            ))
            .fontWeight(.medium)
    }
}

private struct SessionShimmerEffect: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let phase = CGFloat(t.truncatingRemainder(dividingBy: 2.0) / 2.0)

                content
                    .overlay {
                        GeometryReader { geo in
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0), location: max(0, phase - 0.2)),
                                    .init(color: .white.opacity(0.3), location: phase),
                                    .init(color: .white.opacity(0), location: min(1, phase + 0.2))
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                            .frame(width: geo.size.width, height: geo.size.height)
                        }
                        .blendMode(.sourceAtop)
                    }
                    .compositingGroup()
            }
        } else {
            content
        }
    }
}
