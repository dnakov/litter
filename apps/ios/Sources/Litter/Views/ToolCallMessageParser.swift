import Foundation

enum ToolCallKind: String, Equatable {
    case commandExecution
    case commandOutput
    case fileChange
    case fileDiff
    case mcpToolCall
    case mcpToolProgress
    case webSearch
    case collaboration
    case imageView

    var title: String {
        switch self {
        case .commandExecution: return "Command Execution"
        case .commandOutput: return "Command Output"
        case .fileChange: return "File Change"
        case .fileDiff: return "File Diff"
        case .mcpToolCall: return "MCP Tool Call"
        case .mcpToolProgress: return "MCP Tool Progress"
        case .webSearch: return "Web Search"
        case .collaboration: return "Collaboration"
        case .imageView: return "Image View"
        }
    }

    var iconName: String {
        switch self {
        case .commandExecution, .commandOutput:
            return "terminal.fill"
        case .fileChange:
            return "doc.text.fill"
        case .fileDiff:
            return "arrow.left.arrow.right.square.fill"
        case .mcpToolCall:
            return "wrench.and.screwdriver.fill"
        case .mcpToolProgress:
            return "clock.arrow.trianglehead.counterclockwise.rotate.90"
        case .webSearch:
            return "globe"
        case .collaboration:
            return "person.2.fill"
        case .imageView:
            return "photo.fill"
        }
    }

    static func from(title: String) -> ToolCallKind? {
        let normalized = title
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.contains("command output") { return .commandOutput }
        if normalized.contains("command execution") || normalized == "command" { return .commandExecution }
        if normalized.contains("file change") { return .fileChange }
        if normalized.contains("file diff") || normalized == "diff" { return .fileDiff }
        if normalized.contains("mcp tool progress") { return .mcpToolProgress }
        if normalized.contains("mcp tool call") || normalized == "mcp" { return .mcpToolCall }
        if normalized.contains("web search") { return .webSearch }
        if normalized.contains("collaboration") || normalized.contains("collab") { return .collaboration }
        if normalized.contains("image view") || normalized == "image" { return .imageView }
        return nil
    }
}

enum ToolCallStatus: Equatable {
    case inProgress
    case completed
    case failed
    case unknown

    var label: String {
        switch self {
        case .inProgress: return "In Progress"
        case .completed: return "Completed"
        case .failed: return "Failed"
        case .unknown: return "Unknown"
        }
    }

    var summarySuffix: String {
        switch self {
        case .inProgress: return "in progress"
        case .completed: return "completed"
        case .failed: return "failed"
        case .unknown: return "unknown"
        }
    }
}

struct ToolCallKeyValue: Equatable {
    let key: String
    let value: String
}

enum ToolCallSection: Equatable {
    case kv(label: String, entries: [ToolCallKeyValue])
    case code(label: String, language: String, content: String)
    case json(label: String, content: String)
    case diff(label: String, content: String)
    case text(label: String, content: String)
    case list(label: String, items: [String])
    case progress(label: String, items: [String])
}

struct ToolCallCardModel: Equatable {
    let kind: ToolCallKind
    let title: String
    let summary: String
    let status: ToolCallStatus
    let duration: String?
    let sections: [ToolCallSection]

    var defaultExpanded: Bool { status == .failed }
}

enum ToolCallParseResult: Equatable {
    case recognized(ToolCallCardModel)
    case unrecognized
}

enum ToolCallMessageParser {
    private static let leadingKeySet: Set<String> = [
        "status",
        "tool",
        "duration",
        "path",
        "kind",
        "query",
        "targets",
        "exit code",
        "directory",
        "approval",
        "error"
    ]

    private static let namedSectionSet: Set<String> = [
        "command",
        "arguments",
        "result",
        "output",
        "prompt",
        "action",
        "progress",
        "error"
    ]

    static func parse(message: ChatMessage) -> ToolCallParseResult {
        guard message.role == .system else { return .unrecognized }
        guard let system = parseSystemEnvelope(message.text),
              let kind = ToolCallKind.from(title: system.title) else {
            return .unrecognized
        }
        guard !system.body.isEmpty else { return .unrecognized }

        let body = parseBody(system.body, kind: kind)
        if body.metadata.isEmpty && body.primarySections.isEmpty && body.auxSections.isEmpty {
            return .unrecognized
        }

        let status = inferredStatus(for: kind, raw: body.metadataValue(for: "status"))
        let duration = body.metadataValue(for: "duration")
        let allSections: [ToolCallSection] =
            body.metadata.isEmpty
            ? (body.primarySections + body.auxSections)
            : [.kv(label: "Metadata", entries: body.metadata)] + body.primarySections + body.auxSections

        let summary = summaryFor(kind: kind, title: system.title, status: status, duration: duration, body: body)

        return .recognized(
            ToolCallCardModel(
                kind: kind,
                title: system.title,
                summary: summary,
                status: status,
                duration: duration,
                sections: allSections
            )
        )
    }

    private struct ParsedSystemMessage {
        let title: String
        let body: String
    }

    private struct ParsedFence {
        let language: String
        let content: String
    }

    private struct RawSection {
        let label: String?
        let content: String
    }

    private struct ParsedBody {
        var metadata: [ToolCallKeyValue]
        var primarySections: [ToolCallSection]
        var auxSections: [ToolCallSection]
        var filePaths: [String]

        func metadataValue(for key: String) -> String? {
            let normalized = normalizeToken(key)
            return metadata.first { normalizeToken($0.key) == normalized }?.value
        }
    }

    private struct FenceState {
        let marker: Character
        let length: Int
    }

    private static func parseSystemEnvelope(_ text: String) -> ParsedSystemMessage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### "),
              let firstLine = trimmed.split(separator: "\n", omittingEmptySubsequences: false).first else {
            return nil
        }
        let title = firstLine.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let bodyStart = trimmed.index(trimmed.startIndex, offsetBy: firstLine.count)
        let body = String(trimmed[bodyStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedSystemMessage(title: title, body: body)
    }

    private static func parseBody(_ body: String, kind: ToolCallKind) -> ParsedBody {
        let lines = body.components(separatedBy: "\n")
        var index = 0
        var metadata: [ToolCallKeyValue] = []
        var filePaths: [String] = []
        var auxSections: [ToolCallSection] = []

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                if metadata.isEmpty {
                    index += 1
                    continue
                }
                index += 1
                break
            }
            if parseSectionHeader(trimmed) != nil {
                break
            }
            guard let keyValue = parseKeyValueLine(trimmed) else {
                break
            }
            let normalizedKey = normalizeToken(keyValue.key)
            guard leadingKeySet.contains(normalizedKey) else {
                break
            }

            if normalizedKey == "targets" {
                let items = keyValue.value
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !items.isEmpty {
                    auxSections.append(.list(label: "Targets", items: items))
                }
            } else {
                metadata.append(keyValue)
                if normalizedKey == "path", !keyValue.value.isEmpty {
                    filePaths.append(keyValue.value)
                }
            }
            index += 1
        }

        let remainder = lines.dropFirst(index).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        var primarySections: [ToolCallSection] = []

        if !remainder.isEmpty {
            switch kind {
            case .fileChange:
                let parsed = parseFileChangeSections(remainder: remainder)
                primarySections.append(contentsOf: parsed.sections)
                filePaths.append(contentsOf: parsed.paths)
            default:
                let rawSections = splitNamedSections(remainder)
                for raw in rawSections {
                    appendSection(raw, kind: kind, primary: &primarySections, aux: &auxSections)
                }
            }
        }

        if kind == .mcpToolProgress && auxSections.isEmpty && !remainder.isEmpty {
            let items = remainder
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                auxSections.append(.progress(label: "Progress", items: items))
            }
        }

        return ParsedBody(
            metadata: metadata,
            primarySections: primarySections,
            auxSections: auxSections,
            filePaths: filePaths
        )
    }

    private static func parseFileChangeSections(remainder: String) -> (sections: [ToolCallSection], paths: [String]) {
        let chunks = splitTopLevel(remainder, onSeparator: "---")
        var sections: [ToolCallSection] = []
        var paths: [String] = []

        for (index, chunk) in chunks.enumerated() {
            let lines = chunk.components(separatedBy: "\n")
            var cursor = 0
            var entryMetadata: [ToolCallKeyValue] = []
            while cursor < lines.count {
                let trimmed = lines[cursor].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    cursor += 1
                    break
                }
                guard let keyValue = parseKeyValueLine(trimmed),
                      ["path", "kind"].contains(normalizeToken(keyValue.key)) else {
                    break
                }
                entryMetadata.append(keyValue)
                if normalizeToken(keyValue.key) == "path" {
                    paths.append(keyValue.value)
                }
                cursor += 1
            }

            if !entryMetadata.isEmpty {
                sections.append(.kv(label: "Change \(index + 1)", entries: entryMetadata))
            }

            let content = lines.dropFirst(cursor).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if content.isEmpty { continue }
            if let fence = parseSingleFence(content) {
                let language = normalizeToken(fence.language)
                if language == "diff" {
                    sections.append(.diff(label: "Diff", content: fence.content))
                } else if language == "json" {
                    sections.append(.json(label: "Content", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    sections.append(.text(label: "Content", content: fence.content))
                } else {
                    sections.append(.code(label: "Content", language: fence.language, content: fence.content))
                }
            } else {
                sections.append(.text(label: "Content", content: content))
            }
        }

        return (sections, paths)
    }

    private static func splitNamedSections(_ text: String) -> [RawSection] {
        let lines = text.components(separatedBy: "\n")
        var sections: [RawSection] = []
        var currentLabel: String?
        var buffer: [String] = []
        var sawNamedSection = false
        var fenceState: FenceState?

        func flush() {
            let content = buffer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty || currentLabel != nil {
                sections.append(RawSection(label: currentLabel, content: content))
            }
            buffer = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fenceState == nil, let header = parseSectionHeader(trimmed) {
                sawNamedSection = true
                flush()
                currentLabel = header.label
                if !header.inlineValue.isEmpty {
                    buffer.append(header.inlineValue)
                }
                continue
            }

            buffer.append(line)
            updateFenceState(for: line, state: &fenceState)
        }
        flush()

        if !sawNamedSection {
            return [RawSection(label: nil, content: text.trimmingCharacters(in: .whitespacesAndNewlines))]
        }

        return sections
    }

    private static func splitTopLevel(_ text: String, onSeparator separator: String) -> [String] {
        let lines = text.components(separatedBy: "\n")
        var chunks: [String] = []
        var current: [String] = []
        var fenceState: FenceState?

        func flush() {
            let content = current.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !content.isEmpty { chunks.append(content) }
            current = []
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if fenceState == nil, trimmed == separator {
                flush()
                continue
            }

            current.append(line)
            updateFenceState(for: line, state: &fenceState)
        }
        flush()
        return chunks
    }

    private static func appendSection(
        _ raw: RawSection,
        kind: ToolCallKind,
        primary: inout [ToolCallSection],
        aux: inout [ToolCallSection]
    ) {
        let label = raw.label?.capitalized
        let content = raw.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return }

        if let label {
            switch normalizeToken(label) {
            case "command":
                let section = parseCodeLike(label: "Command", content: content, fallbackLanguage: "bash")
                primary.append(section)
            case "arguments":
                primary.append(parseJSONLike(label: "Arguments", content: content))
            case "result":
                primary.append(parseJSONLike(label: "Result", content: content))
            case "output":
                primary.append(parseOutputLike(label: "Output", content: content))
            case "action":
                primary.append(parseJSONLike(label: "Action", content: content))
            case "prompt":
                aux.append(.text(label: "Prompt", content: content))
            case "progress":
                let items = content
                    .split(separator: "\n")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                if !items.isEmpty {
                    aux.append(.progress(label: "Progress", items: items))
                }
            case "error":
                primary.append(parseOutputLike(label: "Error", content: content))
            default:
                primary.append(.text(label: label, content: content))
            }
            return
        }

        switch kind {
        case .commandOutput:
            primary.append(parseOutputLike(label: "Output", content: content))
        case .fileDiff:
            if let fence = parseSingleFence(content), normalizeToken(fence.language) == "diff" {
                primary.append(.diff(label: "Diff", content: fence.content))
            } else {
                primary.append(.diff(label: "Diff", content: content))
            }
        case .mcpToolProgress:
            let items = content
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !items.isEmpty {
                aux.append(.progress(label: "Progress", items: items))
            }
        default:
            if let fence = parseSingleFence(content) {
                let language = normalizeToken(fence.language)
                if language == "json" {
                    primary.append(.json(label: "Details", content: fence.content))
                } else if language == "diff" {
                    primary.append(.diff(label: "Diff", content: fence.content))
                } else if language == "text" || language.isEmpty {
                    primary.append(.text(label: "Details", content: fence.content))
                } else {
                    primary.append(.code(label: "Details", language: fence.language, content: fence.content))
                }
            } else {
                primary.append(.text(label: "Details", content: content))
            }
        }
    }

    private static func parseCodeLike(label: String, content: String, fallbackLanguage: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let language = fence.language.isEmpty ? fallbackLanguage : fence.language
            return .code(label: label, language: language, content: fence.content)
        }
        return .code(label: label, language: fallbackLanguage, content: content)
    }

    private static func parseJSONLike(label: String, content: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let language = normalizeToken(fence.language)
            if language == "json" || language.isEmpty {
                return .json(label: label, content: fence.content)
            }
            if language == "diff" {
                return .diff(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        if looksLikeJSON(content) {
            return .json(label: label, content: content)
        }
        return .text(label: label, content: content)
    }

    private static func parseOutputLike(label: String, content: String) -> ToolCallSection {
        if let fence = parseSingleFence(content) {
            let language = normalizeToken(fence.language)
            if language == "diff" {
                return .diff(label: label, content: fence.content)
            }
            if language == "json" {
                return .json(label: label, content: fence.content)
            }
            if language == "text" || language.isEmpty {
                return .text(label: label, content: fence.content)
            }
            return .code(label: label, language: fence.language, content: fence.content)
        }
        return .text(label: label, content: content)
    }

    private static func summaryFor(
        kind: ToolCallKind,
        title: String,
        status: ToolCallStatus,
        duration: String?,
        body: ParsedBody
    ) -> String {
        switch kind {
        case .commandExecution, .commandOutput:
            if let command = commandSummary(from: body.primarySections) {
                var result = stripShellWrapper(command)
                if status == .completed {
                    result += " ✓"
                } else if status != .unknown {
                    result += " (\(status.summarySuffix))"
                }
                if let duration, !duration.isEmpty {
                    result += " \(duration)"
                }
                return result
            }
        case .fileChange, .fileDiff:
            if let first = body.filePaths.first {
                let basename = URL(fileURLWithPath: first).lastPathComponent
                if body.filePaths.count > 1 {
                    return "\(basename) +\(body.filePaths.count - 1) files"
                }
                return basename.isEmpty ? first : basename
            }
        case .mcpToolCall, .mcpToolProgress:
            if let tool = body.metadataValue(for: "tool"), !tool.isEmpty {
                if status == .completed {
                    return "\(tool) ✓"
                }
                if status != .unknown {
                    return "\(tool) (\(status.summarySuffix))"
                }
                return tool
            }
        case .webSearch:
            if let query = body.metadataValue(for: "query"), !query.isEmpty {
                return query
            }
        case .imageView:
            if let path = body.metadataValue(for: "path"), !path.isEmpty {
                let basename = URL(fileURLWithPath: path).lastPathComponent
                return basename.isEmpty ? path : basename
            }
        case .collaboration:
            if let tool = body.metadataValue(for: "tool"), !tool.isEmpty {
                return tool
            }
        }

        if let duration, !duration.isEmpty, status != .unknown {
            return "\(title) (\(status.summarySuffix), \(duration))"
        }
        if status != .unknown {
            return "\(title) (\(status.summarySuffix))"
        }
        return title
    }

    private static func commandSummary(from sections: [ToolCallSection]) -> String? {
        for section in sections {
            switch section {
            case .code(let label, _, let content), .text(let label, let content):
                if normalizeToken(label) == "command" {
                    return content
                        .split(separator: "\n")
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .first { !$0.isEmpty }
                }
            default:
                continue
            }
        }
        return nil
    }

    private static func stripShellWrapper(_ command: String) -> String {
        var value = command.trimmingCharacters(in: .whitespacesAndNewlines)
        let wrappers = ["/bin/zsh -lc '", "/bin/bash -lc '"]
        for wrapper in wrappers where value.hasPrefix(wrapper) && value.hasSuffix("'") {
            value = String(value.dropFirst(wrapper.count).dropLast())
        }
        return value
    }

    private static func inferredStatus(for kind: ToolCallKind, raw: String?) -> ToolCallStatus {
        let normalized = normalizeStatus(raw: raw)
        if normalized != .unknown {
            return normalized
        }

        // Legacy and resumed web search messages may not include an explicit
        // status line; treat them as completed instead of showing "Unknown".
        if kind == .webSearch {
            return .completed
        }
        return .unknown
    }

    private static func normalizeStatus(raw: String?) -> ToolCallStatus {
        let normalized = normalizeToken(raw ?? "")
        switch normalized {
        case "inprogress", "in progress", "running", "pending", "started":
            return .inProgress
        case "completed", "complete", "success", "ok", "done":
            return .completed
        case "failed", "failure", "error", "denied", "cancelled", "aborted":
            return .failed
        default:
            return .unknown
        }
    }

    private static func parseSingleFence(_ text: String) -> ParsedFence? {
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first else { return nil }
        let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
        guard let opening = openingFence(in: firstTrimmed) else { return nil }

        var collected: [String] = []
        var closed = false
        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isClosingFence(trimmed, marker: opening.marker, minLength: opening.length) {
                closed = true
                break
            }
            collected.append(line)
        }
        guard closed else { return nil }

        let language = String(firstTrimmed.dropFirst(opening.length)).trimmingCharacters(in: .whitespacesAndNewlines)
        let content = collected.joined(separator: "\n").trimmingCharacters(in: .newlines)
        return ParsedFence(language: language, content: content)
    }

    private static func parseKeyValueLine(_ line: String) -> ToolCallKeyValue? {
        guard let separator = line.firstIndex(of: ":") else { return nil }
        let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
        let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        return ToolCallKeyValue(key: key, value: value)
    }

    private static func parseSectionHeader(_ line: String) -> (label: String, inlineValue: String)? {
        guard let keyValue = parseKeyValueLine(line) else { return nil }
        let normalized = normalizeToken(keyValue.key)
        guard namedSectionSet.contains(normalized) else { return nil }
        return (keyValue.key, keyValue.value)
    }

    private static func openingFence(in line: String) -> (marker: Character, length: Int)? {
        guard let marker = line.first, marker == "`" || marker == "~" else { return nil }
        let length = line.prefix(while: { $0 == marker }).count
        guard length >= 3 else { return nil }
        return (marker, length)
    }

    private static func isClosingFence(_ line: String, marker: Character, minLength: Int) -> Bool {
        guard line.first == marker else { return false }
        let length = line.prefix(while: { $0 == marker }).count
        guard length >= minLength else { return false }
        let remainder = line.dropFirst(length).trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty
    }

    private static func updateFenceState(for line: String, state: inout FenceState?) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if let active = state {
            if isClosingFence(trimmed, marker: active.marker, minLength: active.length) {
                state = nil
            }
            return
        }
        if let opening = openingFence(in: trimmed) {
            state = FenceState(marker: opening.marker, length: opening.length)
        }
    }

    private static func normalizeToken(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeJSON(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if ["{", "[", "\"", "-", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "t", "f", "n"].contains(String(trimmed.first!)) {
            return (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil
        }
        return false
    }
}
