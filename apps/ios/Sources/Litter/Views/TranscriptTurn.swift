import Foundation

struct TranscriptTurn: Identifiable, Equatable {
    struct Preview: Equatable {
        let primaryText: String
        let secondaryText: String?
        let durationText: String?
        let imageCount: Int
        let toolCallCount: Int
        let eventCount: Int
        let widgetCount: Int
    }

    let id: String
    let items: [ConversationItem]
    let preview: Preview
    let isLive: Bool
    let isCollapsedByDefault: Bool
    let renderDigest: Int

    static func build(
        from items: [ConversationItem],
        threadStatus: ConversationStatus,
        expandedRecentTurnCount: Int = 3
    ) -> [TranscriptTurn] {
        let groupedItems = group(items)
        guard !groupedItems.isEmpty else { return [] }
        let isStreaming: Bool
        if case .thinking = threadStatus {
            isStreaming = true
        } else {
            isStreaming = false
        }

        let lastIndex = groupedItems.index(before: groupedItems.endIndex)

        let collapseBoundary = max(0, groupedItems.count - expandedRecentTurnCount)

        return groupedItems.enumerated().map { index, turnItems in
            let isLive = isStreaming && index == lastIndex
            return TranscriptTurn(
                id: turnIdentifier(for: turnItems, ordinal: index),
                items: turnItems,
                preview: makePreview(from: turnItems),
                isLive: isLive,
                isCollapsedByDefault: index < collapseBoundary,
                renderDigest: makeRenderDigest(from: turnItems, isLive: isLive)
            )
        }
    }

    func withCollapsedByDefault(_ isCollapsedByDefault: Bool) -> TranscriptTurn {
        TranscriptTurn(
            id: id,
            items: items,
            preview: preview,
            isLive: isLive,
            isCollapsedByDefault: isCollapsedByDefault,
            renderDigest: renderDigest
        )
    }

    private static func group(_ items: [ConversationItem]) -> [[ConversationItem]] {
        var groups: [[ConversationItem]] = []
        var current: [ConversationItem] = []
        var currentSourceTurnId: String?

        for item in items {
            let startsNewTurn =
                !current.isEmpty &&
                (
                    item.isFromUserTurnBoundary ||
                    (
                        item.sourceTurnId != nil &&
                        currentSourceTurnId != nil &&
                        item.sourceTurnId != currentSourceTurnId
                    )
                )

            if startsNewTurn {
                groups.append(current)
                current = [item]
            } else {
                current.append(item)
            }

            // Adopt the first non-nil sourceTurnId in the group so that
            // assistant items following a user-boundary item (which has
            // sourceTurnId == nil) stay in the same turn.
            if currentSourceTurnId == nil {
                currentSourceTurnId = item.sourceTurnId
            } else if current.count == 1 {
                currentSourceTurnId = current.first?.sourceTurnId
            }
        }

        if !current.isEmpty {
            groups.append(current)
        }

        return groups
    }

    private static func turnIdentifier(for items: [ConversationItem], ordinal: Int) -> String {
        if let first = items.first {
            if let sourceTurnId = items.first(where: { $0.sourceTurnId != nil })?.sourceTurnId {
                return "turn-\(sourceTurnId)-\(first.id)"
            }
            return "turn-\(first.id)"
        }
        return "turn-\(ordinal)"
    }

    private static func makeRenderDigest(from items: [ConversationItem], isLive: Bool) -> Int {
        var hasher = Hasher()
        hasher.combine(items.count)
        hasher.combine(isLive)
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.renderDigest)
        }
        return hasher.finalize()
    }

    private static func makePreview(from items: [ConversationItem]) -> Preview {
        let primaryItem = items.first(where: \.isUserItem) ?? items.first
        let secondaryItem =
            items.first {
                guard let primaryItem else { return true }
                return $0.id != primaryItem.id && ($0.isAssistantItem || isPreviewSecondary($0))
            }

        return Preview(
            primaryText: previewText(for: primaryItem),
            secondaryText: secondaryItem.map(previewText(for:)),
            durationText: formattedDuration(for: items),
            imageCount: items.reduce(0) { $0 + $1.userImages.count },
            toolCallCount: toolCallCount(in: items),
            eventCount: eventCount(in: items),
            widgetCount: items.filter { $0.widgetState != nil }.count
        )
    }

    private static func isPreviewSecondary(_ item: ConversationItem) -> Bool {
        switch item.content {
        case .note, .divider, .error, .reasoning:
            return true
        default:
            return false
        }
    }

    private static func previewText(for item: ConversationItem?) -> String {
        guard let item else { return "Conversation turn" }

        switch item.content {
        case .user(let data):
            let trimmed = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return collapsedExcerpt(from: trimmed) }
            if !data.images.isEmpty {
                return data.images.count == 1 ? "Shared 1 image" : "Shared \(data.images.count) images"
            }
            return "Conversation turn"
        case .assistant(let data):
            let trimmed = data.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Assistant response" : collapsedExcerpt(from: trimmed)
        case .reasoning(let data):
            let body = (data.summary + data.content)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? "Reasoning" : "Reasoning: \(collapsedExcerpt(from: body))"
        case .todoList(let data):
            if data.steps.isEmpty {
                return "To do list"
            }
            let completed = data.completedCount
            let total = data.steps.count
            if completed == 0 {
                return "To do list: \(total) tasks"
            }
            return "To do list: \(completed) of \(total) done"
        case .proposedPlan(let data):
            let trimmed = data.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Plan" : "Plan: \(collapsedExcerpt(from: trimmed))"
        case .commandExecution(let data):
            if let action = data.actions.first {
                switch action.kind {
                case .read:
                    return action.path.map { "Read \($0)" } ?? "Read file"
                case .search:
                    if let query = action.query, let path = action.path {
                        return "Searched for \(query) in \(path)"
                    }
                    if let query = action.query {
                        return "Searched for \(query)"
                    }
                    return "Searched files"
                case .listFiles:
                    return action.path.map { "Listed files in \($0)" } ?? "Listed files"
                case .unknown:
                    break
                }
            }
            return data.command.isEmpty ? "Ran command" : collapsedExcerpt(from: "Ran \(data.command)")
        case .fileChange(let data):
            if let first = data.changes.first {
                return "Changed \(first.path)"
            }
            return "File changes"
        case .turnDiff:
            return "Turn diff"
        case .mcpToolCall(let data):
            return data.server.isEmpty ? "Called \(data.tool)" : "Called \(data.tool) from \(data.server)"
        case .dynamicToolCall(let data):
            return "Called \(data.tool)"
        case .multiAgentAction(let data):
            let count = max(data.targets.count, data.agentStates.count)
            return count == 1 ? "\(data.tool) 1 agent" : "\(data.tool) \(count) agents"
        case .webSearch(let data):
            return data.query.isEmpty ? "Searched web" : "Searched web for \(data.query)"
        case .widget(let data):
            return "Widget: \(data.widgetState.title)"
        case .userInputResponse(let data):
            let count = data.questions.count
            return count == 1 ? "Asked 1 question" : "Asked \(count) questions"
        case .divider(let divider):
            switch divider {
            case .contextCompaction(let isComplete):
                return isComplete ? "Context compacted" : "Compacting context"
            case .modelRerouted(_, let toModel, _):
                return "Routed to \(toModel)"
            case .reviewEntered(let review):
                return "Entered review: \(review)"
            case .reviewExited(let review):
                return "Exited review: \(review)"
            case .workedFor(let duration):
                return duration
            case .generic(let title, let detail):
                return detail.map { "\(title): \(collapsedExcerpt(from: $0))" } ?? title
            }
        case .error(let data):
            return data.title.isEmpty ? collapsedExcerpt(from: data.message) : "\(data.title): \(collapsedExcerpt(from: data.message))"
        case .note(let data):
            return data.body.isEmpty ? data.title : "\(data.title): \(collapsedExcerpt(from: data.body))"
        }
    }

    private static func formattedDuration(for items: [ConversationItem]) -> String? {
        let userTimestamp =
            items.first(where: { $0.isUserItem && $0.isFromUserTurnBoundary })?.timestamp ??
            items.first(where: \.isUserItem)?.timestamp
        let assistantTimestamp = items.last(where: \.isAssistantItem)?.timestamp

        if let userTimestamp,
           let assistantTimestamp {
            let interval = max(0, assistantTimestamp.timeIntervalSince(userTimestamp))
            if interval >= 0.05 {
                return formatDuration(seconds: interval)
            }
        }

        if let explicitMillis = explicitDurationMillis(in: items) {
            return formatDuration(milliseconds: explicitMillis)
        }

        return nil
    }

    private static func explicitDurationMillis(in items: [ConversationItem]) -> Int? {
        let total = items.reduce(into: 0) { runningTotal, item in
            switch item.content {
            case .commandExecution(let data):
                if let durationMs = data.durationMs {
                    runningTotal += durationMs
                }
            case .mcpToolCall(let data):
                if let durationMs = data.durationMs {
                    runningTotal += durationMs
                }
            case .dynamicToolCall(let data):
                if let durationMs = data.durationMs {
                    runningTotal += durationMs
                }
            default:
                break
            }
        }

        return total > 0 ? total : nil
    }

    private static func formatDuration(milliseconds: Int) -> String {
        if milliseconds < 1000 {
            return "\(milliseconds)ms"
        }
        return formatDuration(seconds: Double(milliseconds) / 1000)
    }

    private static func formatDuration(seconds interval: TimeInterval) -> String {
        if interval < 1 {
            return "\(Int((interval * 1000).rounded()))ms"
        }

        if interval < 10 {
            let roundedTenths = (interval * 10).rounded() / 10
            if roundedTenths.rounded() == roundedTenths {
                return "\(Int(roundedTenths))s"
            }
            return "\(roundedTenths.formatted(.number.precision(.fractionLength(1))))s"
        }

        if interval < 60 {
            return "\(Int(interval.rounded()))s"
        }

        let totalSeconds = Int(interval.rounded())
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if totalSeconds < 3600 {
            return seconds == 0 ? "\(minutes)m" : "\(minutes)m \(seconds)s"
        }

        let hours = totalSeconds / 3600
        let remainingMinutes = (totalSeconds % 3600) / 60
        return remainingMinutes == 0 ? "\(hours)h" : "\(hours)h \(remainingMinutes)m"
    }

    private static func toolCallCount(in items: [ConversationItem]) -> Int {
        items.reduce(into: 0) { count, item in
            switch item.content {
            case .commandExecution,
                 .fileChange,
                 .turnDiff,
                 .mcpToolCall,
                 .dynamicToolCall,
                 .multiAgentAction,
                 .webSearch:
                count += 1
            default:
                break
            }
        }
    }

    private static func eventCount(in items: [ConversationItem]) -> Int {
        items.reduce(into: 0) { count, item in
            switch item.content {
            case .divider, .error, .note, .userInputResponse:
                count += 1
            default:
                break
            }
        }
    }

    private static func collapsedExcerpt(from text: String) -> String {
        let normalized = text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != "```" }
            .joined(separator: " ")

        if normalized.count <= 180 {
            return normalized
        }

        let endIndex = normalized.index(normalized.startIndex, offsetBy: 180)
        return String(normalized[..<endIndex]).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
