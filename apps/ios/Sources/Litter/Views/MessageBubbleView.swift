import SwiftUI
import MarkdownUI
import Inject

struct MessageBubbleView: View {
    @ObserveInjection var inject
    let message: ChatMessage
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var mdSystemBodySize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var mdSystemCodeSize: CGFloat = 12
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            if message.role == .user {
                Spacer(minLength: 60)
                userBubble
            } else if message.role == .assistant {
                assistantContent
                Spacer(minLength: 20)
            } else if isReasoning {
                reasoningContent
                Spacer(minLength: 20)
            } else {
                systemBubble
                Spacer(minLength: 20)
            }
        }
        .enableInjection()
    }

    private var isReasoning: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return false }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        return firstLine.lowercased().contains("reason")
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(message.images) { img in
                if let uiImage = UIImage(data: img.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 14, tint: LitterTheme.accent.opacity(0.3)))
    }

    private var assistantContent: some View {
        let parsed = extractInlineImages(message.text)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parsed.enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let md):
                    Markdown(md)
                        .markdownTheme(.litter(bodySize: mdBodySize, codeSize: mdCodeSize))
                        .markdownCodeSyntaxHighlighter(.plain)
                        .textSelection(.enabled)
                case .imageData(let data):
                    if let uiImage = UIImage(data: data) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(body)
            .font(.system(.footnote, design: .monospaced))
            .italic()
            .foregroundColor(LitterTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var isToolCall: Bool {
        let (title, _) = extractSystemTitleAndBody(message.text)
        guard let t = title?.lowercased() else { return false }
        return t.contains("command") || t.contains("file") || t.contains("mcp")
            || t.contains("web") || t.contains("collab") || t.contains("image")
    }

    private var systemBubble: some View {
        let (title, body) = extractSystemTitleAndBody(message.text)
        let theme = systemTheme(for: title)
        let toolCall = isToolCall
        let summary = toolCall ? compactSummary(title: title, body: body) : nil

        return VStack(alignment: .leading, spacing: 0) {
            // Header row — always visible, tappable for tool calls
            HStack(spacing: 6) {
                Image(systemName: theme.icon)
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(theme.accent)
                if toolCall, let summary {
                    Text(summary)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(LitterTheme.textSystem)
                        .lineLimit(1)
                } else if let title {
                    Text(title.uppercased())
                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                        .foregroundColor(theme.accent)
                }
                Spacer()
                if toolCall {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundColor(LitterTheme.textMuted)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if toolCall { withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() } }
            }

            // Expanded body
            if !toolCall || expanded {
                Markdown(body)
                    .markdownTheme(.litterSystem(bodySize: mdSystemBodySize, codeSize: mdSystemCodeSize))
                    .markdownCodeSyntaxHighlighter(.plain)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 12))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1)
                .fill(theme.accent.opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func compactSummary(title: String?, body: String) -> String {
        guard let title = title?.lowercased() else { return "" }
        let lines = body.components(separatedBy: "\n")

        if title.contains("command") {
            // Extract command from the code block after "Command:"
            if let cmdIdx = lines.firstIndex(where: { $0.hasPrefix("Command:") }),
               cmdIdx + 2 < lines.count {
                let cmd = lines[cmdIdx + 2] // line after ```bash
                    .trimmingCharacters(in: .whitespaces)
                // Strip shell wrapper
                let short = cmd
                    .replacingOccurrences(of: "/bin/zsh -lc '", with: "")
                    .replacingOccurrences(of: "/bin/bash -lc '", with: "")
                    .replacingOccurrences(of: "'", with: "")
                let status = lines.first { $0.hasPrefix("Status:") }?
                    .replacingOccurrences(of: "Status: ", with: "") ?? ""
                let duration = lines.first { $0.contains("Duration:") }
                    .flatMap { line -> String? in
                        guard let range = line.range(of: "Duration: ") else { return nil }
                        return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                var result = short
                if status == "completed" { result += " ✓" }
                else if !status.isEmpty { result += " (\(status))" }
                if let d = duration { result += " \(d)" }
                return result
            }
        }

        if title.contains("file") {
            let paths = lines.filter { $0.hasPrefix("Path: ") }
                .map { $0.replacingOccurrences(of: "Path: ", with: "") }
            if let first = paths.first {
                let name = (first as NSString).lastPathComponent
                if paths.count > 1 {
                    return "\(name) +\(paths.count - 1) files"
                }
                return name
            }
        }

        if title.contains("mcp") {
            if let toolLine = lines.first(where: { $0.hasPrefix("Tool: ") }) {
                let tool = toolLine.replacingOccurrences(of: "Tool: ", with: "")
                let status = lines.first { $0.hasPrefix("Status:") }?
                    .replacingOccurrences(of: "Status: ", with: "") ?? ""
                if status == "completed" { return "\(tool) ✓" }
                return "\(tool) (\(status))"
            }
        }

        if title.contains("web") {
            if let queryLine = lines.first(where: { $0.hasPrefix("Query: ") }) {
                return queryLine.replacingOccurrences(of: "Query: ", with: "")
            }
        }

        return title.capitalized
    }

    private func extractSystemTitleAndBody(_ text: String) -> (String?, String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return (nil, trimmed) }
        let lines = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first else { return (nil, trimmed) }
        let title = first.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines)
        let body = lines.dropFirst().joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (title.isEmpty ? nil : title, body)
    }

    private func systemTheme(for title: String?) -> (accent: Color, icon: String) {
        guard let title = title?.lowercased() else {
            return (Color(hex: "#8CB3A4"), "info.circle.fill")
        }
        if title.contains("command") {
            return (Color(hex: "#C7B072"), "terminal.fill")
        }
        if title.contains("file") {
            return (Color(hex: "#7CAFD9"), "doc.text.fill")
        }
        if title.contains("mcp") {
            return (Color(hex: "#C797D8"), "wrench.and.screwdriver.fill")
        }
        if title.contains("plan") {
            return (Color(hex: "#9BCF8E"), "list.bullet.rectangle.portrait.fill")
        }
        if title.contains("reason") {
            return (Color(hex: "#E3A66F"), "brain.head.profile")
        }
        if title.contains("web") {
            return (Color(hex: "#88C6C7"), "globe")
        }
        if title.contains("review") {
            return (Color(hex: "#D69696"), "checkmark.seal.fill")
        }
        if title.contains("context") {
            return (Color(hex: "#AFAFAF"), "archivebox.fill")
        }
        return (Color(hex: "#8CB3A4"), "info.circle.fill")
    }

    // MARK: - Inline image extraction

    private enum ContentSegment {
        case text(String)
        case imageData(Data)
    }

    private func extractInlineImages(_ text: String) -> [ContentSegment] {
        // Match markdown images with data URIs: ![...](data:image/...;base64,...)
        // Also match bare data URIs: data:image/...;base64,...
        let pattern = "!\\[[^\\]]*\\]\\(data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)\\)|(?<![\\(])data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return [.text(text)]
        }

        var segments: [ContentSegment] = []
        var lastEnd = text.startIndex
        let nsRange = NSRange(text.startIndex..., in: text)

        for match in regex.matches(in: text, range: nsRange) {
            guard let matchRange = Range(match.range, in: text) else { continue }

            // Add preceding text
            if lastEnd < matchRange.lowerBound {
                let preceding = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preceding.isEmpty { segments.append(.text(preceding)) }
            }

            // Try capture group 1 (markdown image) then group 2 (bare data URI)
            let base64String: String?
            if match.range(at: 1).location != NSNotFound, let r = Range(match.range(at: 1), in: text) {
                base64String = String(text[r])
            } else if match.range(at: 2).location != NSNotFound, let r = Range(match.range(at: 2), in: text) {
                base64String = String(text[r])
            } else {
                base64String = nil
            }

            if let b64 = base64String,
               let data = Data(base64Encoded: b64.replacingOccurrences(of: "\\s", with: "", options: .regularExpression), options: .ignoreUnknownCharacters) {
                segments.append(.imageData(data))
            }

            lastEnd = matchRange.upperBound
        }

        // Add remaining text
        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty { segments.append(.text(remaining)) }
        }

        return segments.isEmpty ? [.text(text)] : segments
    }
}

// MARK: - Plain syntax highlighter (no highlighting, just monospace)

struct PlainSyntaxHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        Text(code)
    }
}

extension CodeSyntaxHighlighter where Self == PlainSyntaxHighlighter {
    static var plain: PlainSyntaxHighlighter { PlainSyntaxHighlighter() }
}

// MARK: - Litter Markdown Theme

extension MarkdownUI.Theme {
    static func litter(bodySize: CGFloat, codeSize: CGFloat) -> Theme {
        Theme()
            .text {
                ForegroundColor(LitterTheme.textBody)
                FontFamily(.custom("SFMono-Regular"))
                FontSize(bodySize)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(bodySize * 1.43)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.21)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.07)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(.white)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(LitterTheme.accent)
            }
            .code {
                FontFamily(.custom("SFMono-Regular"))
                FontSize(codeSize)
                ForegroundColor(LitterTheme.accent)
                BackgroundColor(LitterTheme.surface)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    language: configuration.language ?? "",
                    code: configuration.content
                )
                .markdownMargin(top: 8, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 4, bottom: 4)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(LitterTheme.textSecondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LitterTheme.border)
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 8, bottom: 8)
            }
            .thematicBreak {
                Divider()
                    .overlay(LitterTheme.border)
                    .markdownMargin(top: 12, bottom: 12)
            }
    }

    static func litterSystem(bodySize: CGFloat, codeSize: CGFloat) -> Theme {
        Theme()
            .text {
                ForegroundColor(LitterTheme.textSystem)
                FontFamily(.custom("SFMono-Regular"))
                FontSize(bodySize)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(bodySize * 1.31)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.15)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.08)
                        ForegroundColor(.white)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(.white)
            }
            .emphasis {
                FontStyle(.italic)
            }
            .link {
                ForegroundColor(LitterTheme.accent)
            }
            .code {
                FontFamily(.custom("SFMono-Regular"))
                FontSize(codeSize)
                ForegroundColor(LitterTheme.accent)
                BackgroundColor(LitterTheme.surface)
            }
            .codeBlock { configuration in
                CodeBlockView(
                    language: configuration.language ?? "",
                    code: configuration.content
                )
                .markdownMargin(top: 6, bottom: 6)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 3, bottom: 3)
            }
            .blockquote { configuration in
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(LitterTheme.textSecondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(LitterTheme.border)
                            .frame(width: 3)
                    }
                    .markdownMargin(top: 6, bottom: 6)
            }
            .thematicBreak {
                Divider()
                    .overlay(LitterTheme.border)
                    .markdownMargin(top: 8, bottom: 8)
            }
    }
}
