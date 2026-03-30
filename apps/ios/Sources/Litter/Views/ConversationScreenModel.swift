import Foundation
import Observation

struct ConversationTranscriptSnapshot {
    var items: [ConversationItem]
    var threadStatus: ConversationStatus
    var followScrollToken: Int
    var agentDirectoryVersion: UInt64

    static let empty = ConversationTranscriptSnapshot(
        items: [],
        threadStatus: .ready,
        followScrollToken: 0,
        agentDirectoryVersion: 0
    )
}

struct ConversationComposerSnapshot {
    var threadKey: ThreadKey
    var pendingUserInputRequest: PendingUserInputRequest?
    var queuedFollowUps: [AppQueuedFollowUpPreview]
    var composerPrefillRequest: AppModel.ComposerPrefillRequest?
    var activeTurnId: String?
    var isTurnActive: Bool
    var threadPreview: String
    var threadModel: String
    var threadReasoningEffort: String?
    var modelContextWindow: Int64?
    var contextTokensUsed: Int64?
    var rateLimits: RateLimitSnapshot?
    var availableModels: [ModelInfo]
    var isConnected: Bool

    static let empty = ConversationComposerSnapshot(
        threadKey: ThreadKey(serverId: "", threadId: ""),
        pendingUserInputRequest: nil,
        queuedFollowUps: [],
        composerPrefillRequest: nil,
        activeTurnId: nil,
        isTurnActive: false,
        threadPreview: "",
        threadModel: "",
        threadReasoningEffort: nil,
        modelContextWindow: nil,
        contextTokensUsed: nil,
        rateLimits: nil,
        availableModels: [],
        isConnected: false
    )
}

@MainActor
@Observable
final class ConversationScreenModel {
    private(set) var transcript: ConversationTranscriptSnapshot = .empty
    private(set) var pinnedContextItems: [ConversationItem] = []
    private(set) var composer: ConversationComposerSnapshot = .empty

    @ObservationIgnored private var thread: AppThreadSnapshot?
    @ObservationIgnored private var appModel: AppModel?
    @ObservationIgnored private var agentDirectoryVersion: UInt64 = 0
    @ObservationIgnored private var followScrollToken = 0
    @ObservationIgnored private var lastObservedUpdatedAt: Date?

    func bind(
        thread: AppThreadSnapshot,
        appModel: AppModel,
        agentDirectoryVersion: UInt64
    ) {
        let needsRebind =
            self.thread != thread ||
            self.appModel !== appModel ||
            self.agentDirectoryVersion != agentDirectoryVersion

        self.thread = thread
        self.appModel = appModel
        self.agentDirectoryVersion = agentDirectoryVersion

        if needsRebind {
            followScrollToken = 0
            lastObservedUpdatedAt = nil
        }

        refreshState()
    }

    private func refreshState() {
        guard let thread, let appModel else {
            transcript = .empty
            pinnedContextItems = []
            composer = .empty
            lastObservedUpdatedAt = nil
            return
        }

        let items = thread.hydratedConversationItems.map(\.conversationItem)
        let threadStatus = conversationStatus(from: thread)
        let updatedAt = Date(timeIntervalSince1970: TimeInterval(thread.info.updatedAt ?? 0))
        let activeTurnId: String?
        if let value = thread.activeTurnId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !value.isEmpty {
            activeTurnId = value
        } else {
            activeTurnId = nil
        }
        let hasTurnInFlight = activeTurnId != nil || thread.info.status == .active
        let pendingUserInputRequest = appModel.snapshot?.pendingUserInputs.first {
            $0.serverId == thread.key.serverId && $0.threadId == thread.key.threadId
        }
        let composerPrefillRequest = appModel.composerPrefillRequest.flatMap { request in
            request.threadKey == thread.key ? request : nil
        }
        let composerSnapshot = ConversationComposerSnapshot(
            threadKey: thread.key,
            pendingUserInputRequest: pendingUserInputRequest,
            queuedFollowUps: thread.queuedFollowUps,
            composerPrefillRequest: composerPrefillRequest,
            activeTurnId: activeTurnId,
            isTurnActive: activeTurnId != nil,
            threadPreview: thread.resolvedPreview,
            threadModel: thread.resolvedModel,
            threadReasoningEffort: thread.reasoningEffort,
            modelContextWindow: thread.modelContextWindow.map(Int64.init),
            contextTokensUsed: thread.contextTokensUsed.map(Int64.init),
            rateLimits: appModel.rateLimits(for: thread.key.serverId),
            availableModels: appModel.availableModels(for: thread.key.serverId),
            isConnected: appModel.snapshot?.serverSnapshot(for: thread.key.serverId)?.isConnected ?? false
        )

        if let lastObservedUpdatedAt,
           updatedAt != lastObservedUpdatedAt,
           hasTurnInFlight {
            followScrollToken &+= 1
        }
        lastObservedUpdatedAt = updatedAt

        pinnedContextItems = items
        transcript = ConversationTranscriptSnapshot(
            items: items,
            threadStatus: threadStatus,
            followScrollToken: followScrollToken,
            agentDirectoryVersion: agentDirectoryVersion
        )
        composer = composerSnapshot
    }
}

private func conversationStatus(from thread: AppThreadSnapshot) -> ConversationStatus {
    switch thread.info.status {
    case .active:
        return .thinking
    case .systemError:
        return .error("Session error")
    case .notLoaded:
        return .connecting
    case .idle:
        return .ready
    }
}
