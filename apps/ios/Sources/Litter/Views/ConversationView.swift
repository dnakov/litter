import SwiftUI
import PhotosUI
import UIKit
import Inject
import os

private let conversationViewSignpostLog = OSLog(
    subsystem: Bundle.main.bundleIdentifier ?? "com.litter.ios",
    category: "ConversationView"
)

struct ConversationView: View {
    @ObserveInjection var inject
    @Environment(AppState.self) private var appState
    let connection: ServerConnection
    let activeThreadKey: ThreadKey
    let serverManager: ServerManager
    let transcript: ConversationTranscriptSnapshot
    let pinnedContextItems: [ConversationItem]
    let composer: ConversationComposerSnapshot
    var topInset: CGFloat = 0
    var bottomInset: CGFloat = 0
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    var onResumeSessions: ((String) -> Void)? = nil
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"
    @AppStorage("conversationTextSizeStep") private var conversationTextSizeStep = ConversationTextSize.medium.rawValue
    @State private var messageActionError: String?
    @State private var hasLoggedFirstRender = false

    private var items: [ConversationItem] {
        transcript.items
    }

    private var threadStatus: ConversationStatus {
        transcript.threadStatus
    }

    private var followScrollToken: Int {
        transcript.followScrollToken
    }

    private var agentDirectoryVersion: Int {
        transcript.agentDirectoryVersion
    }

    private var pendingModelOverride: String? {
        let trimmed = appState.selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var pendingReasoningOverride: String? {
        let trimmed = appState.reasoningEffort.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private var activeThread: ThreadState? {
        serverManager.threads[activeThreadKey]
    }

    var body: some View {
        ConversationMessageList(
            items: items,
            threadStatus: threadStatus,
            followScrollToken: followScrollToken,
            activeThreadKey: activeThreadKey,
            agentDirectoryVersion: agentDirectoryVersion,
            topInset: activeThread?.isSubagent == true ? topInset + 32 : topInset,
            textSizeStep: $conversationTextSizeStep,
            resolveTargetLabel: resolveTargetLabel,
            onWidgetPrompt: sendWidgetPrompt,
            onEditUserItem: editMessage,
            onForkFromUserItem: forkFromMessage,
            onOpenConversation: onOpenConversation
        )
        .background(LitterTheme.backgroundGradient.ignoresSafeArea())
        .mask {
            VStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                    .frame(height: 60)
                Rectangle().fill(.black)
            }
            .ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let thread = activeThread, thread.isSubagent {
                SubagentBreadcrumbBar(
                    thread: thread,
                    topInset: topInset,
                    onNavigateToParent: {
                        if let parentId = thread.parentThreadId {
                            onOpenConversation?(ThreadKey(serverId: thread.serverId, threadId: parentId))
                        }
                    }
                )
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConversationBottomChrome(
                pinnedContextItems: pinnedContextItems,
                textScale: ConversationTextSize.clamped(rawValue: conversationTextSizeStep).scale,
                composer: composer,
                connection: connection,
                serverManager: serverManager,
                onSend: sendMessage,
                onFileSearch: searchComposerFiles,
                bottomInset: bottomInset,
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions
            )
        }
        .alert("Conversation Action Error", isPresented: Binding(
            get: { messageActionError != nil },
            set: { if !$0 { messageActionError = nil } }
        )) {
            Button("OK", role: .cancel) { messageActionError = nil }
        } message: {
            Text(messageActionError ?? "Unknown error")
        }
        .onAppear {
            guard !hasLoggedFirstRender else { return }
            hasLoggedFirstRender = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "ConversationFirstRender")
        }
        .enableInjection()
    }

    private func sendMessage(_ text: String, skillMentions: [SkillMentionSelection]) {
        Task {
            await serverManager.send(
                text,
                skillMentions: skillMentions,
                cwd: workDir,
                model: pendingModelOverride,
                effort: pendingReasoningOverride,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
        }
    }

    private func sendWidgetPrompt(_ text: String) {
        guard !text.isEmpty else { return }
        Task {
            await serverManager.send(
                text,
                cwd: workDir,
                model: pendingModelOverride,
                effort: pendingReasoningOverride,
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
        }
    }

    private func resolveTargetLabel(_ target: String) -> String? {
        serverManager.resolvedAgentTargetLabel(for: target, serverId: activeThreadKey.serverId)
    }

    private func editMessage(_ item: ConversationItem) {
        Task {
            do {
                try await serverManager.editMessage(item)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func forkFromMessage(_ item: ConversationItem) {
        Task {
            do {
                let nextKey = try await serverManager.forkFromMessage(
                    item,
                    approvalPolicy: appState.approvalPolicy,
                    sandboxMode: appState.sandboxMode
                )
                if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                    workDir = nextCwd
                    appState.currentCwd = nextCwd
                }
                onOpenConversation?(nextKey)
            } catch {
                messageActionError = error.localizedDescription
            }
        }
    }

    private func searchComposerFiles(_ query: String) async throws -> [FuzzyFileSearchResult] {
        guard connection.isConnected else {
            throw NSError(
                domain: "Litter",
                code: 2001,
                userInfo: [NSLocalizedDescriptionKey: "No connected server available for file search"]
            )
        }
        let searchRoot = workDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "/" : workDir
        let resp = try await connection.fuzzyFileSearch(
            query: query,
            roots: [searchRoot],
            cancellationToken: "ios-composer-file-search"
        )
        return resp.files
    }
}

private struct ConversationBottomChrome: View {
    let pinnedContextItems: [ConversationItem]
    let textScale: CGFloat
    let composer: ConversationComposerSnapshot
    let connection: ServerConnection
    let serverManager: ServerManager
    let onSend: (String, [SkillMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FuzzyFileSearchResult]
    var bottomInset: CGFloat = 0
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            ConversationPinnedContextStrip(items: pinnedContextItems, textScale: textScale)
            ConversationInputBar(
                snapshot: composer,
                connection: connection,
                serverManager: serverManager,
                onSend: onSend,
                onFileSearch: onFileSearch,
                bottomInset: bottomInset,
                onOpenConversation: onOpenConversation,
                onResumeSessions: onResumeSessions
            )
            .background(.clear, ignoresSafeAreaEdges: .bottom)
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
}

enum ConversationTextSize: Int, CaseIterable {
    case xxSmall = -1
    case xSmall = 0
    case small = 1
    case medium = 2
    case large = 3
    case xLarge = 4
    case xxLarge = 5

    var scale: CGFloat {
        switch self {
        case .xxSmall: return 0.78
        case .xSmall: return 0.86
        case .small: return 0.93
        case .medium: return 1.0
        case .large: return 1.1
        case .xLarge: return 1.22
        case .xxLarge: return 1.36
        }
    }

    var label: String {
        switch self {
        case .xxSmall: return "Smallest"
        case .xSmall: return "Smaller"
        case .small: return "Small"
        case .medium: return "Default"
        case .large: return "Large"
        case .xLarge: return "Larger"
        case .xxLarge: return "Largest"
        }
    }

    static func clamped(rawValue: Int) -> ConversationTextSize {
        let bounded = min(max(rawValue, xxSmall.rawValue), xxLarge.rawValue)
        return ConversationTextSize(rawValue: bounded) ?? .medium
    }
}

struct RateLimitBadgeView: View, Equatable {
    let label: String
    let percent: Int

    private var tint: Color {
        if percent <= 10 { return LitterTheme.danger }
        if percent <= 30 { return LitterTheme.warning }
        return LitterTheme.textMuted
    }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 7.5, weight: .semibold, design: .monospaced))
                .foregroundColor(LitterTheme.textSecondary)
            ContextBadgeView(percent: percent, tint: tint)
        }
    }
}


private struct ConversationMessageList: View {
    let items: [ConversationItem]
    let threadStatus: ConversationStatus
    let followScrollToken: Int
    let activeThreadKey: ThreadKey
    let agentDirectoryVersion: Int
    var topInset: CGFloat = 0
    @Binding var textSizeStep: Int
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil
    @State private var pendingScrollWorkItem: DispatchWorkItem?
    @State private var isNearBottom = true
    @State private var autoFollowStreaming = true
    @State private var userIsDraggingScroll = false
    @State private var streamingRenderTick = 0
    @State private var transcriptLayoutTick = 0
    @State private var pinchBaseStep: Int?
    @State private var pinchAppliedDelta = 0
    @State private var transcriptTurns: [TranscriptTurn] = []
    @State private var expandedTurnIDs: Set<String> = []
    @State private var richRenderedTurnIDs: Set<String> = []
    @State private var pendingAnimatedTurns: [TranscriptTurn]?
    @State private var turnInsertionAnimationInFlight = false
    @State private var pendingRichRenderPromotion: DispatchWorkItem?
    @AppStorage("collapseTurns") private var collapseTurns = false
    private var expandedRecentTurnCount: Int {
        collapseTurns ? 1 : .max
    }

    private var lastTurnIsUserOnly: Bool {
        guard let lastTurn = displayedTurns.last else { return false }
        return lastTurn.items.allSatisfy { $0.isUserItem }
    }

    private var isStreamingLastTurn: Bool {
        if case .thinking = threadStatus { return true }
        return displayedTurns.last?.isLive == true
    }


    private var messageActionsDisabled: Bool {
        if case .thinking = threadStatus {
            return true
        }
        return false
    }

    private var targetTextScale: CGFloat {
        ConversationTextSize.clamped(rawValue: textSizeStep).scale
    }

    private var textScale: CGFloat {
        targetTextScale
    }

    private var shouldShowScrollToBottom: Bool {
        !items.isEmpty && !isNearBottom
    }

    private var isStreaming: Bool {
        if case .thinking = threadStatus {
            return true
        }
        return false
    }

    private var shouldMaintainBottomAnchor: Bool {
        guard !userIsDraggingScroll else { return false }
        if isStreaming {
            return autoFollowStreaming
        }
        return isNearBottom
    }

    private var displayedTurns: [TranscriptTurn] {
        if transcriptTurns.isEmpty {
            return TranscriptTurn.build(
                from: items,
                threadStatus: threadStatus,
                expandedRecentTurnCount: expandedRecentTurnCount
            )
        }
        return transcriptTurns
    }

    var body: some View {

        ScrollViewReader { proxy in
            GeometryReader { viewport in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(displayedTurns) { turn in
                                let isLastTurn = turn.id == displayedTurns.last?.id
                                ConversationTurnRow(
                                    turn: turn,
                                    isExpanded: isTurnExpanded(turn),
                                    canCollapse: turn.isCollapsedByDefault,
                                    isLastTurn: isLastTurn,
                                    viewportHeight: viewport.size.height,
                                    showTypingIndicator: isLastTurn && {
                                        if case .thinking = threadStatus { return true }
                                        return false
                                    }(),
                                    renderMode: renderMode(for: turn),
                                    serverId: activeThreadKey.serverId,
                                    agentDirectoryVersion: agentDirectoryVersion,
                                    textScale: textScale,
                                    messageActionsDisabled: messageActionsDisabled,
                                    onToggleExpansion: {
                                        toggleTurnExpansion(turn)
                                    },
                                    onStreamingSnapshotRendered: turn.isLive ? handleStreamingSnapshotRendered : nil,
                                    resolveTargetLabel: resolveTargetLabel,
                                    onWidgetPrompt: onWidgetPrompt,
                                    onEditUserItem: onEditUserItem,
                                    onForkFromUserItem: onForkFromUserItem,
                                    onOpenConversation: onOpenConversation
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, topInset + 56)

                        Color.clear
                            .frame(height: 1)
                            .id("bottom")
                            .padding(.horizontal, 16)
                    }
                    .frame(maxWidth: .infinity, minHeight: viewport.size.height, alignment: .top)
                }
                .defaultScrollAnchor(.bottom)
                .onAppear {
                    syncTranscriptTurns()
                    syncRichRenderedTurns(reset: true)
                }
                .scrollDismissesKeyboard(.interactively)
                .simultaneousGesture(
                    MagnificationGesture(minimumScaleDelta: 0.03)
                        .onChanged { scale in
                            handlePinchChanged(scale: scale)
                        }
                        .onEnded { scale in
                            finishPinch(scale: scale)
                        }
                )
                .onScrollGeometryChange(for: Bool.self) { geo in
                    let distanceFromBottom = geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height
                    return distanceFromBottom <= 60
                } action: { _, newValue in
                    if newValue != isNearBottom {
                        isNearBottom = newValue
                    }
                    if newValue {
                        autoFollowStreaming = true
                    } else if isStreaming && userIsDraggingScroll {
                        autoFollowStreaming = false
                    }
                }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        pendingScrollWorkItem?.cancel()
                        pendingScrollWorkItem = nil
                        userIsDraggingScroll = true
                        if isStreaming {
                            autoFollowStreaming = false
                        }
                    case .decelerating:
                        userIsDraggingScroll = true
                    default:
                        userIsDraggingScroll = false
                        if isNearBottom {
                            autoFollowStreaming = true
                        }
                    }
                }
                    .onAppear {
                        autoFollowStreaming = true
                        scheduleScrollToBottom(proxy, delay: 0.06, force: true, animation: nil)
                    }
                    .onChange(of: activeThreadKey) {
                        autoFollowStreaming = true
                        syncTranscriptTurns(resetExpansion: true)
                        syncRichRenderedTurns(reset: true)
                        scheduleScrollToBottom(proxy, delay: 0.06, force: true, animation: nil)
                    }
                    .onChange(of: items) { _, _ in
                        syncTranscriptTurns()
                        syncRichRenderedTurns()
                    }
                    .onChange(of: items.count) {
                        scheduleScrollToBottom(proxy)
                    }
                    .onChange(of: threadStatus) {
                        syncTranscriptTurns()
                        syncRichRenderedTurns()
                        if isStreaming {
                            autoFollowStreaming = isNearBottom
                            scheduleScrollToBottom(
                                proxy,
                                delay: 0,
                                animation: .linear(duration: 0.12)
                            )
                        } else {
                            userIsDraggingScroll = false
                            scheduleScrollToBottom(proxy, delay: 0.1, force: true)
                        }
                    }
                    .onChange(of: followScrollToken) {
                        guard isStreaming else { return }
                        scheduleScrollToBottom(
                            proxy,
                            delay: 0.06,
                            animation: .linear(duration: 0.12)
                        )
                    }
                    .onChange(of: streamingRenderTick) {
                        guard isStreaming else { return }
                        scheduleScrollToBottom(
                            proxy,
                            delay: 0,
                            replacePending: true,
                            animation: .linear(duration: 0.09)
                        )
                    }
                    .onChange(of: transcriptLayoutTick) {
                        scheduleScrollToBottom(
                            proxy,
                            delay: 0.01,
                            replacePending: true,
                            animation: nil
                        )
                    }
                    .onDisappear {
                        pendingScrollWorkItem?.cancel()
                        pendingScrollWorkItem = nil
                        pendingRichRenderPromotion?.cancel()
                        pendingRichRenderPromotion = nil
                    }
                .animation(.spring(response: 0.22, dampingFraction: 0.9), value: textSizeStep)

                if shouldShowScrollToBottom {
                    ScrollToBottomIndicator {
                        withAnimation(.interactiveSpring(response: 0.28, dampingFraction: 0.9)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                        isNearBottom = true
                        autoFollowStreaming = true
                    }
                    .padding(.trailing, 14)
                    .padding(.bottom, 10)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            }
        }
    }

    private func isTurnExpanded(_ turn: TranscriptTurn) -> Bool {
        !turn.isCollapsedByDefault || expandedTurnIDs.contains(turn.id)
    }

    private func toggleTurnExpansion(_ turn: TranscriptTurn) {
        guard turn.isCollapsedByDefault else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            if expandedTurnIDs.contains(turn.id) {
                expandedTurnIDs.remove(turn.id)
            } else {
                expandedTurnIDs.insert(turn.id)
                richRenderedTurnIDs.insert(turn.id)
            }
        }
    }

    private func syncTranscriptTurns(resetExpansion: Bool = false) {
        let nextTurns = TranscriptTurn.build(
            from: items,
            threadStatus: threadStatus,
            expandedRecentTurnCount: expandedRecentTurnCount
        )
        if shouldAnimateNewTurnInsertion(from: transcriptTurns, to: nextTurns, resetExpansion: resetExpansion) {
            pendingAnimatedTurns = nextTurns
            guard !turnInsertionAnimationInFlight else { return }
            startNewTurnInsertionAnimation(from: transcriptTurns)
            return
        }

        if turnInsertionAnimationInFlight {
            pendingAnimatedTurns = nextTurns
            return
        }

        applyTranscriptTurns(nextTurns, resetExpansion: resetExpansion)
    }

    private func layoutSignature(for turn: TranscriptTurn) -> Int {
        var hasher = Hasher()
        hasher.combine(turn.id)
        hasher.combine(turn.renderDigest)
        hasher.combine(turn.isLive)
        hasher.combine(turn.isCollapsedByDefault)
        return hasher.finalize()
    }

    private func handlePinchChanged(scale: CGFloat) {
        if pinchBaseStep == nil {
            pinchBaseStep = textSizeStep
            pinchAppliedDelta = 0
        }

        let candidateDelta: Int
        if scale >= 1.18 {
            candidateDelta = 2
        } else if scale >= 1.03 {
            candidateDelta = 1
        } else if scale <= 0.86 {
            candidateDelta = -2
        } else if scale <= 0.97 {
            candidateDelta = -1
        } else {
            candidateDelta = 0
        }
        guard candidateDelta != 0 else { return }

        if pinchAppliedDelta == 0 {
            pinchAppliedDelta = candidateDelta
            return
        }

        let sameDirection = (pinchAppliedDelta > 0 && candidateDelta > 0) || (pinchAppliedDelta < 0 && candidateDelta < 0)
        if sameDirection {
            if abs(candidateDelta) > abs(pinchAppliedDelta) {
                pinchAppliedDelta = candidateDelta
            }
        } else {
            pinchAppliedDelta = candidateDelta
        }
    }

    private func finishPinch(scale: CGFloat) {
        handlePinchChanged(scale: scale)
        let baseline = pinchBaseStep ?? textSizeStep
        let next = ConversationTextSize.clamped(rawValue: baseline + pinchAppliedDelta).rawValue
        if next != textSizeStep {
            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) {
                textSizeStep = next
            }
        }
        pinchBaseStep = nil
        pinchAppliedDelta = 0
    }

    private func handleStreamingSnapshotRendered() {
        streamingRenderTick &+= 1
    }

    private func shouldAnimateNewTurnInsertion(
        from currentTurns: [TranscriptTurn],
        to nextTurns: [TranscriptTurn],
        resetExpansion: Bool
    ) -> Bool {
        guard collapseTurns,
              !resetExpansion,
              !currentTurns.isEmpty,
              nextTurns.count == currentTurns.count + 1,
              currentTurns.last?.id != nextTurns.last?.id,
              let lastTurn = nextTurns.last,
              lastTurn.items.first?.isUserItem == true,
              lastTurn.items.first?.isFromUserTurnBoundary == true else {
            return false
        }

        for (currentTurn, nextTurn) in zip(currentTurns, nextTurns) {
            guard currentTurn.id == nextTurn.id else { return false }
        }

        return true
    }

    private func startNewTurnInsertionAnimation(from currentTurns: [TranscriptTurn]) {
        guard let previousLastTurnID = currentTurns.last?.id else {
            if let pendingAnimatedTurns {
                applyTranscriptTurns(pendingAnimatedTurns)
                self.pendingAnimatedTurns = nil
            }
            return
        }

        turnInsertionAnimationInFlight = true
        let collapsedTurns = currentTurns.map { turn in
            turn.id == previousLastTurnID ? turn.withCollapsedByDefault(true) : turn
        }

        withAnimation(.snappy(duration: 0.16, extraBounce: 0)) {
            applyTranscriptTurns(
                collapsedTurns,
                removeExpandedTurnID: previousLastTurnID
            )
        } completion: {
            let turnsToInsert = pendingAnimatedTurns ?? collapsedTurns
            let newTurnID = turnsToInsert.last?.id
            withAnimation(.smooth(duration: 0.2)) {
                applyTranscriptTurns(turnsToInsert)
            } completion: {
                turnInsertionAnimationInFlight = false
                let latestTurns = pendingAnimatedTurns ?? turnsToInsert
                pendingAnimatedTurns = nil
                if latestTurns.map(layoutSignature(for:)) != transcriptTurns.map(layoutSignature(for:)) {
                    applyTranscriptTurns(latestTurns)
                }
            }
        }
    }

    private func applyTranscriptTurns(
        _ nextTurns: [TranscriptTurn],
        resetExpansion: Bool = false,
        removeExpandedTurnID: String? = nil
    ) {
        let previousLayoutSignature = transcriptTurns.map(layoutSignature(for:))
        let nextLayoutSignature = nextTurns.map(layoutSignature(for:))
        let nextTurnIDs = Set(nextTurns.map(\.id))
        transcriptTurns = nextTurns
        if resetExpansion {
            expandedTurnIDs.removeAll()
        } else {
            expandedTurnIDs.formIntersection(nextTurnIDs)
        }
        if let removeExpandedTurnID {
            expandedTurnIDs.remove(removeExpandedTurnID)
        }
        if previousLayoutSignature != nextLayoutSignature {
            transcriptLayoutTick &+= 1
        }
    }

    private func renderMode(for turn: TranscriptTurn) -> ConversationTurnRenderMode {
        if !collapseTurns || turn.isLive || richRenderedTurnIDs.contains(turn.id) {
            return .rich
        }
        return .lightweight
    }

    private func syncRichRenderedTurns(reset: Bool = false) {
        let nextTurnIDs = Set(displayedTurns.map(\.id))
        if reset {
            richRenderedTurnIDs = Set(displayedTurns.filter(\.isLive).map(\.id))
        } else {
            richRenderedTurnIDs.formIntersection(nextTurnIDs)
            for turn in displayedTurns where turn.isLive {
                richRenderedTurnIDs.insert(turn.id)
            }
        }
        scheduleRichRenderPromotion()
    }

    private func scheduleRichRenderPromotion() {
        pendingRichRenderPromotion?.cancel()
        pendingRichRenderPromotion = nil

        guard let targetTurn = displayedTurns.last else { return }
        guard !targetTurn.isLive, !richRenderedTurnIDs.contains(targetTurn.id) else { return }

        let work = DispatchWorkItem {
            richRenderedTurnIDs.insert(targetTurn.id)
            pendingRichRenderPromotion = nil
        }
        pendingRichRenderPromotion = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    private func scheduleScrollToBottom(
        _ proxy: ScrollViewProxy,
        delay: TimeInterval = 0.05,
        force: Bool = false,
        replacePending: Bool = false,
        animation: Animation? = .interactiveSpring(response: 0.28, dampingFraction: 0.9)
    ) {
        guard force || shouldMaintainBottomAnchor else { return }
        if force {
            pendingScrollWorkItem?.cancel()
            pendingScrollWorkItem = nil
        } else if replacePending {
            pendingScrollWorkItem?.cancel()
            pendingScrollWorkItem = nil
        } else if pendingScrollWorkItem != nil {
            return
        }
        let work = DispatchWorkItem {
            pendingScrollWorkItem = nil
            guard force || shouldMaintainBottomAnchor else { return }
            if let animation {
                withAnimation(animation) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            } else {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
            isNearBottom = true
        }
        pendingScrollWorkItem = work
        if delay == 0 {
            DispatchQueue.main.async(execute: work)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }
}

private struct ConversationTurnRow: View {
    let turn: TranscriptTurn
    let isExpanded: Bool
    let canCollapse: Bool
    let isLastTurn: Bool
    let viewportHeight: CGFloat
    let showTypingIndicator: Bool
    let renderMode: ConversationTurnRenderMode
    let serverId: String
    let agentDirectoryVersion: Int
    let textScale: CGFloat
    let messageActionsDisabled: Bool
    let onToggleExpansion: () -> Void
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: (String) -> String?
    let onWidgetPrompt: (String) -> Void
    let onEditUserItem: (ConversationItem) -> Void
    let onForkFromUserItem: (ConversationItem) -> Void
    var onOpenConversation: ((ThreadKey) -> Void)? = nil

    var body: some View {
        if isExpanded {
            expandedContent
        } else {
            collapsedCard
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationTurnTimeline(
                items: turn.items,
                isLive: turn.isLive,
                renderMode: renderMode,
                serverId: serverId,
                agentDirectoryVersion: agentDirectoryVersion,
                textScale: textScale,
                messageActionsDisabled: messageActionsDisabled,
                onStreamingSnapshotRendered: onStreamingSnapshotRendered,
                resolveTargetLabel: resolveTargetLabel,
                onWidgetPrompt: onWidgetPrompt,
                onEditUserItem: onEditUserItem,
                onForkFromUserItem: onForkFromUserItem,
                onOpenConversation: onOpenConversation
            )

            if showTypingIndicator {
                TypingIndicator()
            }

            if canCollapse {
                Button("Show Less", systemImage: "chevron.up", action: onToggleExpansion)
                    .font(LitterFont.styled(.caption, weight: .semibold, scale: textScale))
                    .foregroundColor(LitterTheme.textSecondary)
                    .buttonStyle(.plain)
                    .padding(.top, 2)
            }
        }
        .frame(minHeight: isLastTurn ? viewportHeight * 0.75 : 0, alignment: .top)
        .animation(.smooth(duration: 0.3), value: isLastTurn)
    }

    private var collapsedCard: some View {
        Button(action: onToggleExpansion) {
            previewTextBlock
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .modifier(GlassRectModifier(cornerRadius: 16, tint: LitterTheme.surface.opacity(0.34)))
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var previewTextBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(turn.preview.primaryText)
                .font(LitterFont.styled(.body, weight: .semibold, scale: textScale))
                .foregroundColor(LitterTheme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            ZStack(alignment: .bottomLeading) {
                Text(responsePreviewText)
                    .font(LitterFont.styled(.body, scale: textScale))
                    .foregroundColor(LitterTheme.textSecondary.opacity(0.82))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: collapsedResponseHeight,
                        maxHeight: collapsedResponseHeight,
                        alignment: .topLeading
                    )
                    .mask(responsePreviewMask)

                footerRow
            }
        }
        .frame(maxWidth: .infinity, minHeight: collapsedPreviewHeight, maxHeight: collapsedPreviewHeight, alignment: .topLeading)
    }

    private var footerRow: some View {
        HStack(alignment: .center, spacing: 10) {
            if !footerMetadataItems.isEmpty {
                HStack(spacing: 10) {
                    ForEach(footerMetadataItems, id: \.id) { item in
                        CollapsedTurnMetaItem(
                            systemImage: item.systemImage,
                            text: item.text,
                            textScale: textScale
                        )
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.down")
                .font(.system(size: 11 * textScale, weight: .semibold))
                .foregroundColor(LitterTheme.textMuted)
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 2)
    }

    private var collapsedPreviewHeight: CGFloat {
        collapsedPrimaryLineHeight + collapsedResponseHeight + 4
    }

    private var responsePreviewMask: some View {
        LinearGradient(
            stops: [
                .init(color: .white, location: 0),
                .init(color: .white, location: 0.55),
                .init(color: .white.opacity(0.58), location: 0.82),
                .init(color: .white.opacity(0.24), location: 1),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var collapsedPrimaryLineHeight: CGFloat {
        collapsedPreviewLineHeight
    }

    private var collapsedResponseHeight: CGFloat {
        (collapsedPreviewLineHeight * 2) + 2
    }

    private var collapsedPreviewLineHeight: CGFloat {
        UIFont.preferredFont(forTextStyle: .body).lineHeight * textScale
    }

    private var footerMetadataItems: [CollapsedTurnMeta] {
        var items: [CollapsedTurnMeta] = []
        if let durationText = turn.preview.durationText {
            items.append(CollapsedTurnMeta(id: "duration", systemImage: "clock", text: durationText))
        }
        if turn.preview.toolCallCount > 0 {
            items.append(CollapsedTurnMeta(id: "tools", systemImage: "chevron.left.forwardslash.chevron.right", text: "\(turn.preview.toolCallCount)"))
        }
        if turn.preview.eventCount > 0 {
            items.append(CollapsedTurnMeta(id: "events", systemImage: "sparkles", text: "\(turn.preview.eventCount)"))
        }
        if turn.preview.widgetCount > 0 {
            items.append(CollapsedTurnMeta(id: "widgets", systemImage: "rectangle.3.group", text: "\(turn.preview.widgetCount)"))
        }
        if turn.preview.imageCount > 0 {
            items.append(CollapsedTurnMeta(id: "images", systemImage: "photo", text: "\(turn.preview.imageCount)"))
        }
        return items
    }

    private var secondaryPreviewText: String? {
        guard let secondaryText = turn.preview.secondaryText,
              secondaryText != turn.preview.primaryText else {
            return nil
        }
        return secondaryText
    }

    private var responsePreviewText: String {
        secondaryPreviewText ?? turn.preview.primaryText
    }

    private var accessibilitySummary: String {
        var parts = [turn.preview.primaryText]
        if let secondaryPreviewText {
            parts.append(secondaryPreviewText)
        }
        if let durationText = turn.preview.durationText {
            parts.append("Duration \(durationText)")
        }
        if turn.preview.toolCallCount > 0 {
            parts.append("\(turn.preview.toolCallCount) tool \(turn.preview.toolCallCount == 1 ? "call" : "calls")")
        }
        if turn.preview.widgetCount > 0 {
            parts.append("\(turn.preview.widgetCount) \(turn.preview.widgetCount == 1 ? "widget" : "widgets")")
        }
        if turn.preview.eventCount > 0 {
            parts.append("\(turn.preview.eventCount) \(turn.preview.eventCount == 1 ? "event" : "events")")
        }
        if turn.preview.imageCount > 0 {
            parts.append("\(turn.preview.imageCount) \(turn.preview.imageCount == 1 ? "image" : "images")")
        }
        return parts.joined(separator: ". ")
    }
}

private struct LastTurnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct CollapsedTurnMeta: Identifiable {
    let id: String
    let systemImage: String
    let text: String
}

private struct CollapsedTurnMetaItem: View {
    let systemImage: String
    let text: String
    let textScale: CGFloat

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9 * textScale, weight: .medium))
                .foregroundColor(LitterTheme.textMuted)
            Text(text)
                .font(LitterFont.monospaced(size: 10 * textScale))
                .foregroundColor(LitterTheme.textSecondary)
                .lineLimit(1)
        }
    }
}

private struct ScrollToBottomIndicator: View {
    let action: () -> Void
    @State private var bob = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.down")
                    .font(.system(.caption, weight: .bold))
                    .offset(y: bob ? 1.5 : -1.5)
                Text("Latest")
                    .font(LitterFont.styled(.caption, weight: .semibold))
            }
            .foregroundColor(LitterTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .modifier(GlassCapsuleModifier())
        }
        .contentShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true)) {
                bob = true
            }
        }
    }
}

private struct ConversationInputBar: View {
    @Environment(AppState.self) private var appState
    let snapshot: ConversationComposerSnapshot
    let connection: ServerConnection
    let serverManager: ServerManager
    @AppStorage("workDir") private var workDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path ?? "/"

    let onSend: (String, [SkillMentionSelection]) -> Void
    let onFileSearch: (String) async throws -> [FuzzyFileSearchResult]
    var bottomInset: CGFloat = 0
    let onOpenConversation: ((ThreadKey) -> Void)?
    let onResumeSessions: ((String) -> Void)?

    @State private var inputText = ""
    @State private var showAttachMenu = false
    @State private var showPhotoPicker = false
    @State private var showCamera = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var attachedImage: UIImage?
    @State private var showSlashPopup = false
    @State private var activeSlashToken: ComposerSlashQueryContext?
    @State private var slashSuggestions: [ComposerSlashCommand] = []
    @State private var showFilePopup = false
    @State private var activeAtToken: ComposerTokenContext?
    @State private var showSkillPopup = false
    @State private var activeDollarToken: ComposerTokenContext?
    @State private var fileSearchLoading = false
    @State private var fileSearchError: String?
    @State private var fileSuggestions: [FuzzyFileSearchResult] = []
    @State private var fileSearchGeneration = 0
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var popupRefreshTask: Task<Void, Never>?
    @State private var showModelSelector = false
    @State private var showPermissionsSheet = false
    @State private var showExperimentalSheet = false
    @State private var showSkillsSheet = false
    @State private var showRenamePrompt = false
    @State private var renameCurrentThreadTitle = ""
    @State private var renameDraft = ""
    @State private var slashErrorMessage: String?
    @State private var experimentalFeatures: [ExperimentalFeature] = []
    @State private var experimentalFeaturesLoading = false
    @State private var skills: [SkillMetadata] = []
    @State private var skillsLoading = false
    @State private var mentionSkillPathsByName: [String: String] = [:]
    @State private var hasAttemptedSkillMentionLoad = false
    @State private var voiceManager = VoiceTranscriptionManager()
    @State private var showMicPermissionAlert = false
    @State private var hasLoggedFirstFocus = false
    @State private var hasLoggedKeyboardShown = false
    @FocusState private var isComposerFocused: Bool

    private var pendingUserInputRequest: ServerManager.PendingUserInputRequest? {
        snapshot.pendingUserInputRequest
    }

    private var isTurnActive: Bool {
        snapshot.isTurnActive
    }

    private var popupState: ConversationComposerPopupState {
        if showSlashPopup {
            return .slash(slashSuggestions)
        }
        if showFilePopup {
            return .file(
                loading: fileSearchLoading,
                error: fileSearchError,
                suggestions: fileSuggestions
            )
        }
        if showSkillPopup {
            return .skill(loading: skillsLoading, suggestions: skillSuggestions)
        }
        return .none
    }

    var body: some View {
        ConversationComposerModalCoordinator(
            snapshot: snapshot,
            experimentalFeatures: experimentalFeatures,
            experimentalFeaturesLoading: experimentalFeaturesLoading,
            skills: skills,
            skillsLoading: skillsLoading,
            showAttachMenu: $showAttachMenu,
            showPhotoPicker: $showPhotoPicker,
            showCamera: $showCamera,
            selectedPhoto: $selectedPhoto,
            attachedImage: $attachedImage,
            showModelSelector: $showModelSelector,
            showPermissionsSheet: $showPermissionsSheet,
            showExperimentalSheet: $showExperimentalSheet,
            showSkillsSheet: $showSkillsSheet,
            showRenamePrompt: $showRenamePrompt,
            renameCurrentThreadTitle: $renameCurrentThreadTitle,
            renameDraft: $renameDraft,
            slashErrorMessage: $slashErrorMessage,
            showMicPermissionAlert: $showMicPermissionAlert,
            onOpenSettings: openAppSettings,
            onLoadSelectedPhoto: loadSelectedPhoto,
            onLoadExperimentalFeatures: loadExperimentalFeatures,
            onIsExperimentalFeatureEnabled: { featureId, fallback in
                isExperimentalFeatureEnabled(featureId, fallback: fallback)
            },
            onSetExperimentalFeature: { featureName, enabled in
                await setExperimentalFeature(named: featureName, enabled: enabled)
            },
            onLoadSkills: { forceReload, showErrors in
                await loadSkills(forceReload: forceReload, showErrors: showErrors)
            },
            onRenameThread: renameThread
        ) {
            composerSurface
        }
        .onChange(of: inputText) { _, next in
            scheduleComposerPopupRefresh(for: next)
        }
        .onChange(of: snapshot.composerPrefillRequest?.id) { _, _ in
            guard let prefill = snapshot.composerPrefillRequest else { return }
            inputText = prefill.text
            attachedImage = nil
            hideComposerPopups()
        }
        .onChange(of: isComposerFocused) { _, focused in
            if focused {
                guard !hasLoggedFirstFocus else { return }
                hasLoggedFirstFocus = true
                os_signpost(.event, log: conversationViewSignpostLog, name: "ComposerFirstFocus")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { _ in
            guard !hasLoggedKeyboardShown else { return }
            hasLoggedKeyboardShown = true
            os_signpost(.event, log: conversationViewSignpostLog, name: "KeyboardShown")
        }
        .onDisappear {
            if voiceManager.isRecording { voiceManager.cancelRecording() }
            popupRefreshTask?.cancel()
            popupRefreshTask = nil
            fileSearchTask?.cancel()
            fileSearchTask = nil
        }
    }

    private var composerSurface: some View {
        ConversationComposerContentView(
            attachedImage: attachedImage,
            pendingUserInputRequest: pendingUserInputRequest,
            rateLimits: snapshot.rateLimits,
            contextPercent: contextPercent(),
            isTurnActive: isTurnActive,
            voiceManager: voiceManager,
            onClearAttachment: clearAttachment,
            onRespondToPendingUserInput: respondToPendingUserInput,
            onShowAttachMenu: { showAttachMenu = true },
            onSendText: handleSend,
            onStopRecording: stopVoiceRecording,
            onStartRecording: startVoiceRecording,
            onInterrupt: interruptActiveTurn,
            inputText: $inputText,
            isComposerFocused: $isComposerFocused
        )
        .overlay(alignment: .bottom) {
            ConversationComposerPopupOverlayView(
                state: popupState,
                onApplySlashSuggestion: applySlashSuggestion,
                onApplyFileSuggestion: applyFileSuggestion,
                onApplySkillSuggestion: applySkillSuggestion
            )
        }
    }

    private func contextPercent() -> Int64? {
        guard let contextWindow = snapshot.modelContextWindow else { return nil }
        let baseline: Int64 = 12_000
        guard contextWindow > baseline else { return 0 }
        let totalTokens = snapshot.contextTokensUsed ?? baseline
        let effectiveWindow = contextWindow - baseline
        let usedTokens = max(0, totalTokens - baseline)
        let remainingTokens = max(0, effectiveWindow - usedTokens)
        let percent = Int64((Double(remainingTokens) / Double(effectiveWindow) * 100).rounded())
        return min(max(percent, 0), 100)
    }

    private func clearAttachment() {
        attachedImage = nil
    }

    private func respondToPendingUserInput(_ answers: [String: [String]]) {
        guard let pendingUserInputRequest else { return }
        serverManager.respondToPendingUserInput(
            requestId: pendingUserInputRequest.requestId,
            answers: answers
        )
    }

    private func handleSend() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if attachedImage == nil,
           let invocation = parseSlashCommandInvocation(text) {
            inputText = ""
            attachedImage = nil
            hideComposerPopups()
            isComposerFocused = false
            executeSlashCommand(invocation.command, args: invocation.args)
            return
        }
        inputText = ""
        attachedImage = nil
        hideComposerPopups()
        isComposerFocused = false
        let skillMentions = collectSkillMentionsForSubmission(text)
        onSend(text, skillMentions)
    }

    private func startVoiceRecording() {
        Task {
            let granted = await voiceManager.requestMicPermission()
            guard granted else {
                showMicPermissionAlert = true
                return
            }
            voiceManager.startRecording()
        }
    }

    private func stopVoiceRecording() {
        Task {
            let auth = await connection.getAuthToken()
            if let text = await voiceManager.stopAndTranscribe(
                authMethod: auth.method,
                authToken: auth.token
            ), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                inputText = text
                DispatchQueue.main.async {
                    isComposerFocused = true
                }
            }
        }
    }

    private func interruptActiveTurn() {
        Task { await serverManager.interrupt() }
    }

    private func openAppSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    private func loadSelectedPhoto(_ item: PhotosPickerItem) async {
        if let data = try? await item.loadTransferable(type: Data.self),
           let image = UIImage(data: data) {
            attachedImage = image
        }
        selectedPhoto = nil
    }


    private func clearFileSearchState(incrementGeneration: Bool = true) {
        let hadTask = fileSearchTask != nil
        fileSearchTask?.cancel()
        fileSearchTask = nil
        if incrementGeneration && (hadTask || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty) {
            fileSearchGeneration += 1
        }
        if fileSearchLoading {
            fileSearchLoading = false
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }
    }

    private func hideComposerPopups() {
        popupRefreshTask?.cancel()
        popupRefreshTask = nil
        if showSlashPopup {
            showSlashPopup = false
        }
        if activeSlashToken != nil {
            activeSlashToken = nil
        }
        if !slashSuggestions.isEmpty {
            slashSuggestions = []
        }
        if showFilePopup {
            showFilePopup = false
        }
        if activeAtToken != nil {
            activeAtToken = nil
        }
        if showSkillPopup {
            showSkillPopup = false
        }
        if activeDollarToken != nil {
            activeDollarToken = nil
        }
        clearFileSearchState()
    }

    private func startFileSearch(_ query: String) {
        fileSearchTask?.cancel()
        fileSearchTask = nil
        let requestId = fileSearchGeneration + 1
        fileSearchGeneration = requestId
        if !fileSearchLoading {
            fileSearchLoading = true
        }
        if fileSearchError != nil {
            fileSearchError = nil
        }
        if !fileSuggestions.isEmpty {
            fileSuggestions = []
        }

        fileSearchTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 140_000_000)
            guard !Task.isCancelled else { return }
            guard activeAtToken?.value == query else { return }

            do {
                let matches = try await onFileSearch(query)
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = matches
                fileSearchLoading = false
                fileSearchError = nil
            } catch {
                guard !Task.isCancelled else { return }
                guard requestId == fileSearchGeneration, activeAtToken?.value == query else { return }
                fileSuggestions = []
                fileSearchLoading = false
                fileSearchError = error.localizedDescription
            }
        }
    }

    private func scheduleComposerPopupRefresh(for nextText: String) {
        popupRefreshTask?.cancel()
        let needsPopupEvaluation =
            showSlashPopup ||
            showFilePopup ||
            showSkillPopup ||
            activeSlashToken != nil ||
            activeAtToken != nil ||
            activeDollarToken != nil ||
            nextText.contains("/") ||
            nextText.contains("@") ||
            nextText.contains("$")

        guard needsPopupEvaluation else {
            hideComposerPopups()
            return
        }

        popupRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }
            refreshComposerPopups(for: nextText)
        }
    }

    private func refreshComposerPopups(for nextText: String) {
        let cursor = nextText.count
        if let atToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "@",
            allowEmpty: true
        ) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if showSkillPopup {
                showSkillPopup = false
            }
            if activeDollarToken != nil {
                activeDollarToken = nil
            }
            if !showFilePopup {
                showFilePopup = true
            }
            if activeAtToken != atToken {
                activeAtToken = atToken
                startFileSearch(atToken.value)
            }
            return
        }

        if activeAtToken != nil || showFilePopup || fileSearchTask != nil || fileSearchLoading || fileSearchError != nil || !fileSuggestions.isEmpty {
            activeAtToken = nil
            if showFilePopup {
                showFilePopup = false
            }
            clearFileSearchState()
        }

        if let dollarToken = currentPrefixedToken(
            text: nextText,
            cursor: cursor,
            prefix: "$",
            allowEmpty: true
        ), isMentionQueryValid(dollarToken.value) {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            if !showSkillPopup {
                showSkillPopup = true
            }
            if activeDollarToken != dollarToken {
                activeDollarToken = dollarToken
            }
            if !hasAttemptedSkillMentionLoad && !skillsLoading {
                hasAttemptedSkillMentionLoad = true
                Task { await loadSkills(showErrors: false) }
            }
            return
        }

        if activeDollarToken != nil || showSkillPopup {
            activeDollarToken = nil
            if showSkillPopup {
                showSkillPopup = false
            }
        }

        guard let slashToken = currentSlashQueryContext(text: nextText, cursor: cursor) else {
            if showSlashPopup {
                showSlashPopup = false
            }
            if activeSlashToken != nil {
                activeSlashToken = nil
            }
            if !slashSuggestions.isEmpty {
                slashSuggestions = []
            }
            return
        }

        if activeSlashToken != slashToken {
            activeSlashToken = slashToken
        }
        let suggestions = filterSlashCommands(slashToken.query)
        if slashSuggestions != suggestions {
            slashSuggestions = suggestions
        }
        let shouldShow = !suggestions.isEmpty
        if showSlashPopup != shouldShow {
            showSlashPopup = shouldShow
        }
    }

    private func applySlashSuggestion(_ command: ComposerSlashCommand) {
        showSlashPopup = false
        activeSlashToken = nil
        slashSuggestions = []
        inputText = ""
        attachedImage = nil
        isComposerFocused = false
        executeSlashCommand(command, args: nil)
    }

    private func executeSlashCommand(_ command: ComposerSlashCommand, args: String?) {
        switch command {
        case .model:
            showModelSelector = true
        case .permissions:
            showPermissionsSheet = true
        case .experimental:
            showExperimentalSheet = true
            Task { await loadExperimentalFeatures() }
        case .skills:
            showSkillsSheet = true
            Task { await loadSkills() }
        case .review:
            Task { await startReview() }
        case .rename:
            let initialName = args?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if initialName.isEmpty {
                let currentTitle = snapshot.threadPreview.trimmingCharacters(in: .whitespacesAndNewlines)
                renameCurrentThreadTitle = currentTitle.isEmpty ? "Untitled thread" : currentTitle
                renameDraft = ""
                showRenamePrompt = true
            } else {
                Task { await renameThread(initialName) }
            }
        case .new:
            appState.showServerPicker = true
        case .fork:
            Task { await forkConversation() }
        case .resume:
            onResumeSessions?(snapshot.threadKey.serverId)
        }
    }

    private func parseSlashCommandInvocation(_ text: String) -> (command: ComposerSlashCommand, args: String?)? {
        let firstLine = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let commandAndArgs = trimmed.dropFirst()
        let commandName = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard let command = ComposerSlashCommand(rawCommand: commandName) else { return nil }
        let args = commandAndArgs.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).dropFirst().first.map(String.init)
        return (command, args)
    }

    private func startReview() async {
        do {
            try await serverManager.startReviewOnActiveThread()
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func renameThread(_ newName: String) async {
        do {
            try await serverManager.renameActiveThread(newName)
            showRenamePrompt = false
            renameCurrentThreadTitle = ""
            renameDraft = ""
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func forkConversation() async {
        do {
            let nextKey = try await serverManager.forkActiveThread(
                approvalPolicy: appState.approvalPolicy,
                sandboxMode: appState.sandboxMode
            )
            if let nextCwd = serverManager.activeThread?.cwd, !nextCwd.isEmpty {
                workDir = nextCwd
                appState.currentCwd = nextCwd
            }
            onOpenConversation?(nextKey)
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func loadExperimentalFeatures() async {
        guard connection.isConnected else {
            experimentalFeatures = []
            slashErrorMessage = "Not connected to a server"
            return
        }
        experimentalFeaturesLoading = true
        defer { experimentalFeaturesLoading = false }
        do {
            let response = try await connection.listExperimentalFeatures(limit: 200)
            experimentalFeatures = response.data.sorted { lhs, rhs in
                let left = (lhs.displayName?.isEmpty == false ? lhs.displayName! : lhs.name).lowercased()
                let right = (rhs.displayName?.isEmpty == false ? rhs.displayName! : rhs.name).lowercased()
                return left < right
            }
        } catch {
            slashErrorMessage = error.localizedDescription
        }
    }

    private func isExperimentalFeatureEnabled(_ featureId: String, fallback: Bool) -> Bool {
        experimentalFeatures.first(where: { $0.id == featureId })?.enabled ?? fallback
    }

    private func setExperimentalFeature(named featureName: String, enabled: Bool) async {
        guard connection.isConnected else {
            slashErrorMessage = "Not connected to a server"
            return
        }
        guard let currentIndex = experimentalFeatures.firstIndex(where: { $0.name == featureName }) else {
            return
        }
        let currentFeature = experimentalFeatures[currentIndex]
        if currentFeature.enabled != enabled {
            experimentalFeatures[currentIndex] = ExperimentalFeature(
                name: currentFeature.name,
                stage: currentFeature.stage,
                displayName: currentFeature.displayName,
                description: currentFeature.description,
                announcement: currentFeature.announcement,
                enabled: enabled,
                defaultEnabled: currentFeature.defaultEnabled
            )
        }
        do {
            _ = try await connection.writeConfigValue(keyPath: "features.\(featureName)", value: enabled)
        } catch {
            slashErrorMessage = error.localizedDescription
            if let rollbackIndex = experimentalFeatures.firstIndex(where: { $0.name == currentFeature.name }) {
                experimentalFeatures[rollbackIndex] = ExperimentalFeature(
                    name: currentFeature.name,
                    stage: currentFeature.stage,
                    displayName: currentFeature.displayName,
                    description: currentFeature.description,
                    announcement: currentFeature.announcement,
                    enabled: currentFeature.enabled,
                    defaultEnabled: currentFeature.defaultEnabled
                )
            }
        }
    }

    private func loadSkills(forceReload: Bool = false) async {
        await loadSkills(forceReload: forceReload, showErrors: true)
    }

    private func loadSkills(forceReload: Bool = false, showErrors: Bool) async {
        guard connection.isConnected else {
            skills = []
            mentionSkillPathsByName = [:]
            if showErrors {
                slashErrorMessage = "Not connected to a server"
            }
            return
        }
        skillsLoading = true
        defer { skillsLoading = false }
        do {
            let response = try await connection.listSkills(cwds: [workDir], forceReload: forceReload)
            let loadedSkills = response.data.flatMap(\.skills).sorted { $0.name.lowercased() < $1.name.lowercased() }
            skills = loadedSkills
            let validPaths = Set(loadedSkills.map(\.path))
            mentionSkillPathsByName = mentionSkillPathsByName.filter { _, path in validPaths.contains(path) }
        } catch {
            if showErrors {
                slashErrorMessage = error.localizedDescription
            }
        }
    }

    private func applyFileSuggestion(_ match: FuzzyFileSearchResult) {
        guard let token = activeAtToken else { return }
        let quotedPath = (match.path.contains(" ") && !match.path.contains("\"")) ? "\"\(match.path)\"" : match.path
        let replacement = "\(quotedPath) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        showFilePopup = false
        activeAtToken = nil
        clearFileSearchState()
    }

    private var skillSuggestions: [SkillMetadata] {
        guard let token = activeDollarToken else { return [] }
        return filterSkillSuggestions(token.value)
    }

    private func filterSkillSuggestions(_ query: String) -> [SkillMetadata] {
        guard !skills.isEmpty else { return [] }
        guard !query.isEmpty else { return skills.sorted { lhs, rhs in lhs.name.lowercased() < rhs.name.lowercased() } }
        return skills
            .compactMap { skill -> (SkillMetadata, Int)? in
                let scoreFromName = fuzzyScore(candidate: skill.name, query: query)
                let scoreFromDescription = fuzzyScore(candidate: skill.description, query: query)
                let best = max(scoreFromName ?? Int.min, scoreFromDescription ?? Int.min)
                guard best != Int.min else { return nil }
                return (skill, best)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.name.lowercased() < rhs.0.name.lowercased()
            }
            .map(\.0)
    }

    private func applySkillSuggestion(_ skill: SkillMetadata) {
        guard let token = activeDollarToken else { return }
        let replacement = "$\(skill.name) "
        guard let updated = replacingRange(
            in: inputText,
            with: token.range,
            replacement: replacement
        ) else { return }
        inputText = updated
        mentionSkillPathsByName[skill.name.lowercased()] = skill.path
        showSkillPopup = false
        activeDollarToken = nil
    }

    private func collectSkillMentionsForSubmission(_ text: String) -> [SkillMentionSelection] {
        guard !skills.isEmpty else { return [] }
        let mentionNames = extractMentionNames(text)
        guard !mentionNames.isEmpty else { return [] }

        let skillsByName = Dictionary(grouping: skills, by: { $0.name.lowercased() })
        let skillsByPath = Dictionary(grouping: skills, by: \.path)
        var seenPaths = Set<String>()
        var resolved: [SkillMentionSelection] = []

        for mentionName in mentionNames {
            let normalizedName = mentionName.lowercased()
            if let selectedPath = mentionSkillPathsByName[normalizedName], !selectedPath.isEmpty {
                if let selectedSkill = skillsByPath[selectedPath]?.first {
                    guard seenPaths.insert(selectedPath).inserted else { continue }
                    resolved.append(SkillMentionSelection(name: selectedSkill.name, path: selectedPath))
                    continue
                }
                mentionSkillPathsByName.removeValue(forKey: normalizedName)
            }

            guard let candidates = skillsByName[normalizedName], candidates.count == 1 else {
                continue
            }
            let match = candidates[0]
            guard seenPaths.insert(match.path).inserted else { continue }
            resolved.append(SkillMentionSelection(name: match.name, path: match.path))
        }
        return resolved
    }
}

enum ComposerSlashCommand: CaseIterable {
    case model
    case permissions
    case experimental
    case skills
    case review
    case rename
    case new
    case fork
    case resume

    var rawValue: String {
        switch self {
        case .model: return "model"
        case .permissions: return "permissions"
        case .experimental: return "experimental"
        case .skills: return "skills"
        case .review: return "review"
        case .rename: return "rename"
        case .new: return "new"
        case .fork: return "fork"
        case .resume: return "resume"
        }
    }

    var description: String {
        switch self {
        case .model: return "choose what model and reasoning effort to use"
        case .permissions: return "choose what Codex is allowed to do"
        case .experimental: return "toggle experimental features"
        case .skills: return "use skills to improve how Codex performs specific tasks"
        case .review: return "review my current changes and find issues"
        case .rename: return "rename the current thread"
        case .new: return "start a new chat during a conversation"
        case .fork: return "fork the current conversation into a new session"
        case .resume: return "resume a saved chat"
        }
    }

    init?(rawCommand: String) {
        switch rawCommand.lowercased() {
        case "model": self = .model
        case "permissions": self = .permissions
        case "experimental": self = .experimental
        case "skills": self = .skills
        case "review": self = .review
        case "rename": self = .rename
        case "new": self = .new
        case "fork": self = .fork
        case "resume": self = .resume
        default: return nil
        }
    }
}

enum ComposerPermissionPreset: CaseIterable, Identifiable {
    case readOnly
    case auto
    case fullAccess

    var id: String { title }

    var title: String {
        switch self {
        case .readOnly: return "Read Only"
        case .auto: return "Auto"
        case .fullAccess: return "Full Access"
        }
    }

    var description: String {
        switch self {
        case .readOnly: return "Ask before commands and run in read-only sandbox"
        case .auto: return "No prompts and workspace-write sandbox"
        case .fullAccess: return "No prompts and danger-full-access sandbox"
        }
    }

    var approvalPolicy: String {
        switch self {
        case .readOnly: return "on-request"
        case .auto, .fullAccess: return "never"
        }
    }

    var sandboxMode: String {
        switch self {
        case .readOnly: return "read-only"
        case .auto: return "workspace-write"
        case .fullAccess: return "danger-full-access"
        }
    }
}

private struct ComposerTokenRange: Equatable {
    let start: Int
    let end: Int
}

private struct ComposerTokenContext: Equatable {
    let value: String
    let range: ComposerTokenRange
}

private struct ComposerSlashQueryContext: Equatable {
    let query: String
    let range: ComposerTokenRange
}

private func filterSlashCommands(_ query: String) -> [ComposerSlashCommand] {
    guard !query.isEmpty else { return Array(ComposerSlashCommand.allCases) }
    return ComposerSlashCommand.allCases
        .compactMap { command -> (ComposerSlashCommand, Int)? in
            guard let score = fuzzyScore(candidate: command.rawValue, query: query) else { return nil }
            return (command, score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 {
                return lhs.1 > rhs.1
            }
            return lhs.0.rawValue < rhs.0.rawValue
        }
        .map(\.0)
}

private func fuzzyScore(candidate: String, query: String) -> Int? {
    let normalizedCandidate = candidate.lowercased()
    let normalizedQuery = query.lowercased()

    if normalizedCandidate == normalizedQuery {
        return 1000
    }
    if normalizedCandidate.hasPrefix(normalizedQuery) {
        return 900 - (normalizedCandidate.count - normalizedQuery.count)
    }
    if normalizedCandidate.contains(normalizedQuery) {
        return 700 - (normalizedCandidate.count - normalizedQuery.count)
    }

    var score = 0
    var queryIndex = normalizedQuery.startIndex
    var candidateIndex = normalizedCandidate.startIndex

    while queryIndex < normalizedQuery.endIndex && candidateIndex < normalizedCandidate.endIndex {
        if normalizedQuery[queryIndex] == normalizedCandidate[candidateIndex] {
            score += 10
            queryIndex = normalizedQuery.index(after: queryIndex)
        }
        candidateIndex = normalizedCandidate.index(after: candidateIndex)
    }

    return queryIndex == normalizedQuery.endIndex ? score : nil
}

private let kDollarSign: UInt8 = 0x24
private let kUnderscore: UInt8 = 0x5F
private let kHyphen: UInt8 = 0x2D

private func isMentionNameByte(_ byte: UInt8) -> Bool {
    switch byte {
    case 0x61...0x7A, // a-z
        0x41...0x5A,  // A-Z
        0x30...0x39,  // 0-9
        kUnderscore,
        kHyphen:
        return true
    default:
        return false
    }
}

private func isMentionQueryValid(_ query: String) -> Bool {
    guard !query.isEmpty else { return true }
    return query.utf8.allSatisfy(isMentionNameByte)
}

private func extractMentionNames(_ text: String) -> [String] {
    let bytes = Array(text.utf8)
    guard !bytes.isEmpty else { return [] }

    var mentions: [String] = []
    var index = 0
    while index < bytes.count {
        guard bytes[index] == kDollarSign else {
            index += 1
            continue
        }

        if index > 0, isMentionNameByte(bytes[index - 1]) {
            index += 1
            continue
        }

        let nameStart = index + 1
        guard nameStart < bytes.count, isMentionNameByte(bytes[nameStart]) else {
            index += 1
            continue
        }

        var nameEnd = nameStart + 1
        while nameEnd < bytes.count, isMentionNameByte(bytes[nameEnd]) {
            nameEnd += 1
        }

        if let name = String(bytes: bytes[nameStart..<nameEnd], encoding: .utf8) {
            mentions.append(name)
        }
        index = nameEnd
    }

    return mentions
}

private func currentPrefixedToken(
    text: String,
    cursor: Int,
    prefix: Character,
    allowEmpty: Bool
) -> ComposerTokenContext? {
    guard let tokenRange = tokenRangeAroundCursor(text: text, cursor: cursor) else { return nil }
    guard let tokenText = substring(text, within: tokenRange), tokenText.first == prefix else { return nil }
    let value = String(tokenText.dropFirst())
    if value.isEmpty && !allowEmpty {
        return nil
    }
    return ComposerTokenContext(value: value, range: tokenRange)
}

private func currentSlashQueryContext(
    text: String,
    cursor: Int
) -> ComposerSlashQueryContext? {
    let safeCursor = max(0, min(cursor, text.count))
    let firstLineEnd = text.firstIndex(of: "\n").map { text.distance(from: text.startIndex, to: $0) } ?? text.count
    if safeCursor > firstLineEnd || firstLineEnd <= 0 {
        return nil
    }

    let firstLine = String(text.prefix(firstLineEnd))
    guard firstLine.hasPrefix("/") else { return nil }

    var commandEnd = 1
    let chars = Array(firstLine)
    while commandEnd < chars.count && !chars[commandEnd].isWhitespace {
        commandEnd += 1
    }
    if safeCursor > commandEnd {
        return nil
    }

    let query = commandEnd > 1 ? String(chars[1..<commandEnd]) : ""
    let rest = commandEnd < chars.count ? String(chars[commandEnd...]).trimmingCharacters(in: .whitespacesAndNewlines) : ""

    if query.isEmpty {
        if !rest.isEmpty {
            return nil
        }
    } else if query.contains("/") {
        return nil
    }

    return ComposerSlashQueryContext(query: query, range: ComposerTokenRange(start: 0, end: commandEnd))
}

private func tokenRangeAroundCursor(
    text: String,
    cursor: Int
) -> ComposerTokenRange? {
    guard !text.isEmpty else { return nil }

    let safeCursor = max(0, min(cursor, text.count))
    let chars = Array(text)

    if safeCursor < chars.count, chars[safeCursor].isWhitespace {
        var index = safeCursor
        while index < chars.count && chars[index].isWhitespace {
            index += 1
        }
        if index < chars.count {
            var end = index
            while end < chars.count && !chars[end].isWhitespace {
                end += 1
            }
            return ComposerTokenRange(start: index, end: end)
        }
    }

    var start = safeCursor
    while start > 0 && !chars[start - 1].isWhitespace {
        start -= 1
    }

    var end = safeCursor
    while end < chars.count && !chars[end].isWhitespace {
        end += 1
    }

    if end <= start {
        return nil
    }
    return ComposerTokenRange(start: start, end: end)
}

private func replacingRange(
    in text: String,
    with range: ComposerTokenRange,
    replacement: String
) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    var copy = text
    copy.replaceSubrange(lower..<upper, with: replacement)
    return copy
}

private func substring(_ text: String, within range: ComposerTokenRange) -> String? {
    guard range.start >= 0, range.end <= text.count, range.start <= range.end else { return nil }
    guard let lower = index(in: text, offset: range.start),
          let upper = index(in: text, offset: range.end) else { return nil }
    return String(text[lower..<upper])
}

private func index(in text: String, offset: Int) -> String.Index? {
    guard offset >= 0, offset <= text.count else { return nil }
    return text.index(text.startIndex, offsetBy: offset)
}

struct PendingUserInputPromptView: View {
    let request: ServerManager.PendingUserInputRequest
    let onSubmit: ([String: [String]]) -> Void

    @State private var selectedAnswers: [String: String] = [:]

    private var promptTitle: String {
        let firstQuestion = request.questions.first?.question.lowercased() ?? ""
        if firstQuestion.contains("implement") && firstQuestion.contains("plan") {
            return "Implement Plan"
        }
        return "Input Required"
    }

    private var requesterLabel: String? {
        AgentLabelFormatter.format(
            nickname: request.requesterAgentNickname,
            role: request.requesterAgentRole
        )
    }

    private var unsupportedQuestions: [ServerManager.PendingUserInputQuestion] {
        request.questions.filter { $0.options.isEmpty || $0.isSecret || $0.isOther }
    }

    private var canSubmit: Bool {
        unsupportedQuestions.isEmpty &&
        request.questions.allSatisfy { selectedAnswers[$0.id]?.isEmpty == false }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundColor(LitterTheme.warning)
                Text(promptTitle)
                    .font(LitterFont.styled(.caption, weight: .semibold))
                    .foregroundColor(LitterTheme.textPrimary)
                Spacer()
            }

            if let requesterLabel {
                Text(requesterLabel)
                    .font(LitterFont.styled(.caption2))
                    .foregroundColor(LitterTheme.textMuted)
            }

            ForEach(request.questions, id: \.id) { question in
                VStack(alignment: .leading, spacing: 6) {
                    if !question.header.isEmpty {
                        Text(question.header.uppercased())
                            .font(LitterFont.styled(.caption2, weight: .bold))
                            .foregroundColor(LitterTheme.textMuted)
                    }

                    Text(question.question)
                        .font(LitterFont.styled(.caption))
                        .foregroundColor(LitterTheme.textPrimary)

                    if question.options.isEmpty || question.isSecret || question.isOther {
                        Text("This prompt type is not fully supported in the current iOS client.")
                            .font(LitterFont.styled(.caption2))
                            .foregroundColor(LitterTheme.textSecondary)
                    } else {
                        HStack(spacing: 8) {
                            ForEach(question.options, id: \.label) { option in
                                let isSelected = selectedAnswers[question.id] == option.label
                                Button {
                                    selectedAnswers[question.id] = option.label
                                } label: {
                                    Text(option.label)
                                        .font(LitterFont.styled(.caption2, weight: .semibold))
                                        .foregroundColor(isSelected ? Color.black : LitterTheme.textPrimary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 6)
                                        .background(isSelected ? LitterTheme.accent : LitterTheme.surface.opacity(0.8))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            if canSubmit {
                Button("Submit") {
                    let answers = selectedAnswers.mapValues { [$0] }
                    onSubmit(answers)
                }
                .font(LitterFont.styled(.caption, weight: .semibold))
                .foregroundColor(Color.black)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(LitterTheme.accent)
                .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct TypingIndicator: View {
    @State private var phase = 0
    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(0..<3), id: \.self) { i in
                Circle()
                    .fill(LitterTheme.accent)
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .padding(.leading, 12)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation(.easeInOut(duration: 0.15)) {
                    phase = (phase + 1) % 3
                }
            }
        }
    }
}

struct CameraView: UIViewControllerRepresentable {
    @Binding var image: UIImage?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraView
        init(_ parent: CameraView) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let img = info[.originalImage] as? UIImage {
                parent.image = img
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private struct SubagentBreadcrumbBar: View {
    let thread: ThreadState
    let topInset: CGFloat
    let onNavigateToParent: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onNavigateToParent) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                    Text("Parent")
                        .font(LitterFont.styled(.caption, weight: .medium))
                }
                .foregroundColor(LitterTheme.accent)
            }
            .buttonStyle(.plain)

            Divider()
                .frame(height: 14)
                .background(LitterTheme.border)

            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(LitterTheme.success)
                Text(thread.agentDisplayLabel ?? "Agent")
                    .font(LitterFont.styled(.caption, weight: .medium))
                    .foregroundColor(LitterTheme.textPrimary)
                    .lineLimit(1)
            }

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .padding(.top, topInset + 48)
        .background(
            LitterTheme.surface.opacity(0.85)
                .background(.ultraThinMaterial)
                .ignoresSafeArea()
        )
    }
}

#if DEBUG
#Preview("Conversation") {
    LitterPreviewScene(serverManager: LitterPreviewData.makeServerManager(messages: LitterPreviewData.longConversation)) {
        ContentView()
    }
}
#endif
