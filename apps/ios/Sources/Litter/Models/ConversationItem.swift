import Foundation
import CoreGraphics

enum ConversationPlanStepStatus: String, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct ConversationPlanStep: Equatable {
    let step: String
    let status: ConversationPlanStepStatus
}

enum ConversationCommandActionKind: String, Equatable {
    case read
    case search
    case listFiles
    case unknown
}

struct ConversationCommandAction: Equatable {
    let kind: ConversationCommandActionKind
    let command: String
    let name: String?
    let path: String?
    let query: String?
}

struct ConversationUserMessageData: Equatable {
    var text: String
    var images: [ChatImage]
}

struct ConversationAssistantMessageData: Equatable {
    var text: String
    var agentNickname: String?
    var agentRole: String?
}

struct ConversationReasoningData: Equatable {
    var summary: [String]
    var content: [String]
}

struct ConversationTodoListData: Equatable {
    var steps: [ConversationPlanStep]

    var completedCount: Int {
        steps.filter { $0.status == .completed }.count
    }

    var isComplete: Bool {
        !steps.isEmpty && steps.allSatisfy { $0.status == .completed }
    }
}

struct ConversationProposedPlanData: Equatable {
    var content: String
}

struct ConversationCommandExecutionData: Equatable {
    var command: String
    var cwd: String
    var status: String
    var output: String?
    var exitCode: Int?
    var durationMs: Int?
    var processId: String?
    var actions: [ConversationCommandAction]

    var isInProgress: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("progress")
    }

    var isPureExploration: Bool {
        guard !actions.isEmpty else { return false }
        return actions.allSatisfy {
            switch $0.kind {
            case .read, .search, .listFiles:
                return true
            case .unknown:
                return false
            }
        }
    }
}

struct ConversationFileChangeEntry: Equatable {
    var path: String
    var kind: String
    var diff: String
}

struct ConversationFileChangeData: Equatable {
    var status: String
    var changes: [ConversationFileChangeEntry]
    var outputDelta: String?
}

struct ConversationTurnDiffData: Equatable {
    var diff: String
}

struct ConversationMcpToolCallData: Equatable {
    var server: String
    var tool: String
    var status: String
    var durationMs: Int?
    var argumentsJSON: String?
    var contentSummary: String?
    var structuredContentJSON: String?
    var rawOutputJSON: String?
    var errorMessage: String?
    var progressMessages: [String]

    var isInProgress: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("progress")
    }
}

struct ConversationDynamicToolCallData: Equatable {
    var tool: String
    var status: String
    var durationMs: Int?
    var success: Bool?
    var argumentsJSON: String?
    var contentSummary: String?
}

struct ConversationMultiAgentState: Equatable {
    var targetId: String
    var status: String
    var message: String?
}

struct ConversationMultiAgentActionData: Equatable {
    var tool: String
    var status: String
    var prompt: String?
    var targets: [String]
    var receiverThreadIds: [String]
    var agentStates: [ConversationMultiAgentState]
    /// Per-agent prompts when multiple spawn items are merged into one group.
    /// Index-aligned with `targets`/`receiverThreadIds`. Empty for non-merged items.
    var perAgentPrompts: [String] = []

    var isInProgress: Bool {
        status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().contains("progress")
    }
}

struct ConversationWebSearchData: Equatable {
    var query: String
    var actionJSON: String?
    var isInProgress: Bool
}

struct ConversationWidgetData: Equatable {
    var widgetState: WidgetState
    var status: String
}

struct ConversationUserInputOptionData: Equatable {
    var label: String
    var description: String?
}

struct ConversationUserInputQuestionData: Equatable {
    var id: String
    var header: String?
    var question: String
    var answer: String
    var options: [ConversationUserInputOptionData]
}

struct ConversationUserInputResponseData: Equatable {
    var questions: [ConversationUserInputQuestionData]
}

enum ConversationDividerKind: Equatable {
    case contextCompaction(isComplete: Bool)
    case modelRerouted(fromModel: String?, toModel: String, reason: String?)
    case reviewEntered(String)
    case reviewExited(String)
    case workedFor(String)
    case generic(title: String, detail: String?)
}

struct ConversationSystemErrorData: Equatable {
    var title: String
    var message: String
    var details: String?
}

struct ConversationNoteData: Equatable {
    var title: String
    var body: String
}

enum ConversationItemContent: Equatable {
    case user(ConversationUserMessageData)
    case assistant(ConversationAssistantMessageData)
    case reasoning(ConversationReasoningData)
    case todoList(ConversationTodoListData)
    case proposedPlan(ConversationProposedPlanData)
    case commandExecution(ConversationCommandExecutionData)
    case fileChange(ConversationFileChangeData)
    case turnDiff(ConversationTurnDiffData)
    case mcpToolCall(ConversationMcpToolCallData)
    case dynamicToolCall(ConversationDynamicToolCallData)
    case multiAgentAction(ConversationMultiAgentActionData)
    case webSearch(ConversationWebSearchData)
    case widget(ConversationWidgetData)
    case userInputResponse(ConversationUserInputResponseData)
    case divider(ConversationDividerKind)
    case error(ConversationSystemErrorData)
    case note(ConversationNoteData)
}

struct ConversationItem: Identifiable, Equatable {
    let id: String
    var content: ConversationItemContent {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnId: String? {
        didSet { refreshRenderDigest() }
    }
    var sourceTurnIndex: Int? {
        didSet { refreshRenderDigest() }
    }
    var timestamp: Date {
        didSet { refreshRenderDigest() }
    }
    var isFromUserTurnBoundary: Bool {
        didSet { refreshRenderDigest() }
    }
    private(set) var renderDigest: Int

    init(
        id: String,
        content: ConversationItemContent,
        sourceTurnId: String? = nil,
        sourceTurnIndex: Int? = nil,
        timestamp: Date = Date(),
        isFromUserTurnBoundary: Bool = false
    ) {
        self.id = id
        self.content = content
        self.sourceTurnId = sourceTurnId
        self.sourceTurnIndex = sourceTurnIndex
        self.timestamp = timestamp
        self.isFromUserTurnBoundary = isFromUserTurnBoundary
        self.renderDigest = Self.computeRenderDigest(
            id: id,
            content: content,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }

    var isUserItem: Bool {
        if case .user = content { return true }
        return false
    }

    var isAssistantItem: Bool {
        if case .assistant = content { return true }
        return false
    }

    var agentNickname: String? {
        if case .assistant(let data) = content {
            return data.agentNickname
        }
        return nil
    }

    var agentRole: String? {
        if case .assistant(let data) = content {
            return data.agentRole
        }
        return nil
    }

    var userText: String? {
        if case .user(let data) = content {
            return data.text
        }
        return nil
    }

    var userImages: [ChatImage] {
        if case .user(let data) = content {
            return data.images
        }
        return []
    }

    var assistantText: String? {
        if case .assistant(let data) = content {
            return data.text
        }
        return nil
    }

    var widgetState: WidgetState? {
        if case .widget(let data) = content {
            return data.widgetState
        }
        return nil
    }

    mutating func refreshRenderDigest() {
        renderDigest = Self.computeRenderDigest(
            id: id,
            content: content,
            sourceTurnId: sourceTurnId,
            sourceTurnIndex: sourceTurnIndex,
            timestamp: timestamp,
            isFromUserTurnBoundary: isFromUserTurnBoundary
        )
    }

    private static func computeRenderDigest(
        id: String,
        content: ConversationItemContent,
        sourceTurnId: String?,
        sourceTurnIndex: Int?,
        timestamp: Date,
        isFromUserTurnBoundary: Bool
    ) -> Int {
        var hasher = Hasher()
        hasher.combine(id)
        hasher.combine(sourceTurnId)
        hasher.combine(sourceTurnIndex)
        hasher.combine(timestamp.timeIntervalSince1970)
        hasher.combine(isFromUserTurnBoundary)
        combine(content: content, into: &hasher)
        return hasher.finalize()
    }

    private static func combine(content: ConversationItemContent, into hasher: inout Hasher) {
        switch content {
        case .user(let data):
            hasher.combine("user")
            hasher.combine(data.text)
            hasher.combine(data.images.count)
            for image in data.images {
                hasher.combine(image.data)
            }
        case .assistant(let data):
            hasher.combine("assistant")
            hasher.combine(data.text)
            hasher.combine(data.agentNickname)
            hasher.combine(data.agentRole)
        case .reasoning(let data):
            hasher.combine("reasoning")
            hasher.combine(data.summary)
            hasher.combine(data.content)
        case .todoList(let data):
            hasher.combine("todoList")
            for step in data.steps {
                hasher.combine(step.step)
                hasher.combine(step.status.rawValue)
            }
        case .proposedPlan(let data):
            hasher.combine("proposedPlan")
            hasher.combine(data.content)
        case .commandExecution(let data):
            hasher.combine("commandExecution")
            hasher.combine(data.command)
            hasher.combine(data.cwd)
            hasher.combine(data.status)
            hasher.combine(data.output)
            hasher.combine(data.exitCode)
            hasher.combine(data.durationMs)
            hasher.combine(data.processId)
            for action in data.actions {
                hasher.combine(action.kind.rawValue)
                hasher.combine(action.command)
                hasher.combine(action.name)
                hasher.combine(action.path)
                hasher.combine(action.query)
            }
        case .fileChange(let data):
            hasher.combine("fileChange")
            hasher.combine(data.status)
            hasher.combine(data.outputDelta)
            for change in data.changes {
                hasher.combine(change.path)
                hasher.combine(change.kind)
                hasher.combine(change.diff)
            }
        case .turnDiff(let data):
            hasher.combine("turnDiff")
            hasher.combine(data.diff)
        case .mcpToolCall(let data):
            hasher.combine("mcpToolCall")
            hasher.combine(data.server)
            hasher.combine(data.tool)
            hasher.combine(data.status)
            hasher.combine(data.durationMs)
            hasher.combine(data.argumentsJSON)
            hasher.combine(data.contentSummary)
            hasher.combine(data.structuredContentJSON)
            hasher.combine(data.rawOutputJSON)
            hasher.combine(data.errorMessage)
            hasher.combine(data.progressMessages)
        case .dynamicToolCall(let data):
            hasher.combine("dynamicToolCall")
            hasher.combine(data.tool)
            hasher.combine(data.status)
            hasher.combine(data.durationMs)
            hasher.combine(data.success)
            hasher.combine(data.argumentsJSON)
            hasher.combine(data.contentSummary)
        case .multiAgentAction(let data):
            hasher.combine("multiAgentAction")
            hasher.combine(data.tool)
            hasher.combine(data.status)
            hasher.combine(data.prompt)
            hasher.combine(data.targets)
            hasher.combine(data.receiverThreadIds)
            hasher.combine(data.perAgentPrompts)
            for state in data.agentStates {
                hasher.combine(state.targetId)
                hasher.combine(state.status)
                hasher.combine(state.message)
            }
        case .webSearch(let data):
            hasher.combine("webSearch")
            hasher.combine(data.query)
            hasher.combine(data.actionJSON)
            hasher.combine(data.isInProgress)
        case .widget(let data):
            hasher.combine("widget")
            hasher.combine(data.status)
            hasher.combine(data.widgetState.callId)
            hasher.combine(data.widgetState.title)
            hasher.combine(data.widgetState.widgetHTML)
            hasher.combine(data.widgetState.width)
            hasher.combine(data.widgetState.height)
            hasher.combine(data.widgetState.isFinalized)
        case .userInputResponse(let data):
            hasher.combine("userInputResponse")
            for question in data.questions {
                hasher.combine(question.id)
                hasher.combine(question.header)
                hasher.combine(question.question)
                hasher.combine(question.answer)
                for option in question.options {
                    hasher.combine(option.label)
                    hasher.combine(option.description)
                }
            }
        case .divider(let divider):
            hasher.combine("divider")
            switch divider {
            case .contextCompaction(let isComplete):
                hasher.combine("contextCompaction")
                hasher.combine(isComplete)
            case .modelRerouted(let fromModel, let toModel, let reason):
                hasher.combine("modelRerouted")
                hasher.combine(fromModel)
                hasher.combine(toModel)
                hasher.combine(reason)
            case .reviewEntered(let review):
                hasher.combine("reviewEntered")
                hasher.combine(review)
            case .reviewExited(let review):
                hasher.combine("reviewExited")
                hasher.combine(review)
            case .workedFor(let duration):
                hasher.combine("workedFor")
                hasher.combine(duration)
            case .generic(let title, let detail):
                hasher.combine("genericDivider")
                hasher.combine(title)
                hasher.combine(detail)
            }
        case .error(let data):
            hasher.combine("error")
            hasher.combine(data.title)
            hasher.combine(data.message)
            hasher.combine(data.details)
        case .note(let data):
            hasher.combine("note")
            hasher.combine(data.title)
            hasher.combine(data.body)
        }
    }
}
