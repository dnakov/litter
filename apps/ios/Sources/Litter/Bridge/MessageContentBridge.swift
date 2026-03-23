import Foundation

enum MessageContentBridge {
    enum AssistantContentSegment {
        case markdown(String)
        case inlineImage(Data)
    }

    static func segmentAssistantText(_ text: String) -> [AssistantContentSegment] {
        let parsed = assistantContentSegments(from: store.extractSegmentsTyped(text: text))
        return parsed.isEmpty ? [.markdown(text)] : parsed
    }

    static func parseToolCalls(text: String) -> [ToolCallCardModel] {
        store.parseToolCallsTyped(text: text).compactMap { $0.toToolCallCardModel() }
    }

    private static let store = MessageParser()

    private static func assistantContentSegments(from rustSegments: [FfiMessageSegment]) -> [AssistantContentSegment] {
        rustSegments.compactMap { segment -> AssistantContentSegment? in
            switch segment {
            case .text(text: let text):
                guard !text.isEmpty else { return nil }
                return .markdown(text)
            case .codeBlock(language: let language, code: let code):
                return .markdown(fencedMarkdown(code: code, language: language))
            case .inlineImage(data: let data, mimeType: _):
                return .inlineImage(data)
            }
        }
    }

    private static func fencedMarkdown(code: String, language: String?) -> String {
        let trimmedLanguage = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fenceHeader = trimmedLanguage.isEmpty ? "```" : "```\(trimmedLanguage)"
        return "\(fenceHeader)\n\(code)\n```"
    }
}

private extension FfiToolCallKind {
    func toToolCallKind() -> ToolCallKind? {
        switch self {
        case .commandExecution: return .commandExecution
        case .commandOutput: return .commandOutput
        case .fileChange: return .fileChange
        case .fileDiff: return .fileDiff
        case .mcpToolCall: return .mcpToolCall
        case .mcpToolProgress: return .mcpToolProgress
        case .webSearch: return .webSearch
        case .collaboration: return .collaboration
        case .imageView: return .imageView
        case .widget: return .widget
        case .unknown: return nil
        }
    }
}

private extension FfiToolCallStatus {
    func toToolCallStatus() -> ToolCallStatus {
        switch self {
        case .inProgress: return .inProgress
        case .completed: return .completed
        case .failed: return .failed
        case .unknown: return .unknown
        }
    }
}

private extension FfiToolCallSectionContent {
    func toToolCallSection(label: String) -> ToolCallSection {
        switch self {
        case .keyValue(let entries):
            return .kv(
                label: label,
                entries: entries.map { ToolCallKeyValue(key: $0.key, value: $0.value) }
            )
        case .code(let language, let content):
            return .code(label: label, language: language, content: content)
        case .json(let content):
            return .json(label: label, content: content)
        case .diff(let content):
            return .diff(label: label, content: content)
        case .text(let content):
            return .text(label: label, content: content)
        case .list(let items):
            return .list(label: label, items: items)
        case .progress(let items):
            return .progress(label: label, items: items)
        }
    }
}

private extension FfiToolCallCard {
    func toToolCallCardModel() -> ToolCallCardModel? {
        guard let kind = kind.toToolCallKind() else { return nil }

        let duration: String? = durationMs.map { ms in
            let seconds = Double(ms) / 1000.0
            if seconds < 1.0 {
                return "\(ms)ms"
            } else if seconds < 60.0 {
                return String(format: "%.1fs", seconds)
            } else {
                let minutes = Int(seconds) / 60
                let remainingSeconds = Int(seconds) % 60
                return "\(minutes)m \(remainingSeconds)s"
            }
        }

        return ToolCallCardModel(
            kind: kind,
            title: title,
            summary: summary,
            status: status.toToolCallStatus(),
            duration: duration,
            sections: sections.map { $0.content.toToolCallSection(label: $0.label) }
        )
    }
}
