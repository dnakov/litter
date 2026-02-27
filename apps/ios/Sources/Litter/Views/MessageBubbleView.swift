import SwiftUI
import MarkdownUI
import Inject

struct MessageBubbleView: View {
    @ObserveInjection var inject
    let message: ChatMessage
    let actionsDisabled: Bool
    let onEditUserMessage: ((ChatMessage) -> Void)?
    let onForkFromUserMessage: ((ChatMessage) -> Void)?
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13
    @ScaledMetric(relativeTo: .footnote) private var mdSystemBodySize: CGFloat = 13
    @ScaledMetric(relativeTo: .caption2) private var mdSystemCodeSize: CGFloat = 12
    @State private var parsedAssistantSegments: [ContentSegment] = []
    @State private var didPrepareAssistantSegments = false
    @State private var parsedSystemResult: ToolCallParseResult = .unrecognized
    @State private var didPrepareSystemResult = false

    init(
        message: ChatMessage,
        actionsDisabled: Bool = false,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        onForkFromUserMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.actionsDisabled = actionsDisabled
        self.onEditUserMessage = onEditUserMessage
        self.onForkFromUserMessage = onForkFromUserMessage
    }

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
        .task(id: parseRefreshToken) {
            prepareDerivedContent()
        }
        .enableInjection()
    }

    private var parseRefreshToken: String {
        "\(message.id.uuidString)-\(message.role)-\(message.text.hashValue)-\(message.images.count)"
    }

    private var isReasoning: Bool {
        let trimmed = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("### ") else { return false }
        let firstLine = trimmed.prefix(while: { $0 != "\n" })
        return firstLine.lowercased().contains("reason")
    }

    private var supportsUserActions: Bool {
        message.role == .user &&
            message.isFromUserTurnBoundary &&
            message.sourceTurnIndex != nil
    }

    private var userBubble: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(message.images) { img in
                if let uiImage = decodedImage(from: img.data, cacheKey: "user-\(img.id.uuidString)") {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200, maxHeight: 200)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            if !message.text.isEmpty {
                Text(message.text)
                    .font(LitterFont.monospaced(.callout))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .modifier(GlassRectModifier(cornerRadius: 14, tint: LitterTheme.accent.opacity(0.3)))
        .contextMenu {
            if supportsUserActions {
                Button("Edit Message") {
                    onEditUserMessage?(message)
                }
                .disabled(actionsDisabled || onEditUserMessage == nil)

                Button("Fork From Here") {
                    onForkFromUserMessage?(message)
                }
                .disabled(actionsDisabled || onForkFromUserMessage == nil)
            }
        }
    }

    private var assistantContent: some View {
        let parsed = assistantSegmentsForRendering
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(parsed) { segment in
                switch segment.kind {
                case .text(let md):
                    Markdown(md)
                        .markdownTheme(.litter(bodySize: mdBodySize, codeSize: mdCodeSize))
                        .markdownCodeSyntaxHighlighter(.plain)
                        .textSelection(.enabled)
                case .image(let uiImage):
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(body)
            .font(LitterFont.monospaced(.footnote))
            .italic()
            .foregroundColor(LitterTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var systemBubble: some View {
        let parsed = systemParseResultForRendering
        switch parsed {
        case .recognized(let model):
            ToolCallCardView(model: model)
        case .unrecognized:
            genericSystemBubble
        }
    }

    private var genericSystemBubble: some View {
        let (title, body) = extractSystemTitleAndBody(message.text)
        let markdown = title == nil ? message.text : body
        let displayTitle = title ?? "System"

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "info.circle.fill")
                    .font(.system(.caption2, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                Text(displayTitle.uppercased())
                    .font(LitterFont.monospaced(.caption2, weight: .bold))
                    .foregroundColor(LitterTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                Markdown(markdown)
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
                .fill(LitterTheme.accent.opacity(0.9))
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Inline image extraction

    private struct ContentSegment: Identifiable {
        enum Kind {
            case text(String)
            case image(UIImage)
        }

        let id: String
        let kind: Kind
    }

    private var assistantSegmentsForRendering: [ContentSegment] {
        if didPrepareAssistantSegments {
            return parsedAssistantSegments
        }
        return Self.extractInlineSegments(
            from: message.text,
            messageId: message.id,
            decodeImage: decodedImage(from:cacheKey:)
        )
    }

    private var systemParseResultForRendering: ToolCallParseResult {
        if didPrepareSystemResult {
            return parsedSystemResult
        }
        return ToolCallMessageParser.parse(message: message)
    }

    private func prepareDerivedContent() {
        switch message.role {
        case .assistant:
            parsedAssistantSegments = Self.extractInlineSegments(
                from: message.text,
                messageId: message.id,
                decodeImage: decodedImage(from:cacheKey:)
            )
            didPrepareAssistantSegments = true
            didPrepareSystemResult = false
        case .system:
            parsedSystemResult = ToolCallMessageParser.parse(message: message)
            didPrepareSystemResult = true
            didPrepareAssistantSegments = false
        case .user:
            didPrepareAssistantSegments = false
            didPrepareSystemResult = false
        }
    }

    private static let decodedImageCache = NSCache<NSString, UIImage>()

    private func decodedImage(from data: Data, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = Self.decodedImageCache.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else {
            return nil
        }
        Self.decodedImageCache.setObject(image, forKey: key)
        return image
    }

    private static let inlineImagePattern = "!\\[[^\\]]*\\]\\(data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)\\)|(?<![\\(])data:image/[^;]+;base64,([A-Za-z0-9+/=\\s]+)"
    private static let inlineImageRegex = try? NSRegularExpression(pattern: inlineImagePattern, options: [])

    private static func extractInlineSegments(
        from text: String,
        messageId: UUID,
        decodeImage: (Data, String) -> UIImage?
    ) -> [ContentSegment] {
        // Fast path to avoid regex work on normal markdown text.
        if !text.contains("data:image/") {
            return [ContentSegment(
                id: "text-0-\(text.count)",
                kind: .text(text)
            )]
        }

        // Match markdown images with data URIs: ![...](data:image/...;base64,...)
        // Also match bare data URIs: data:image/...;base64,...
        guard let regex = inlineImageRegex else {
            return [ContentSegment(
                id: "text-0-\(text.count)",
                kind: .text(text)
            )]
        }

        var segments: [ContentSegment] = []
        var lastEnd = text.startIndex
        let nsRange = NSRange(text.startIndex..., in: text)

        for match in regex.matches(in: text, range: nsRange) {
            guard let matchRange = Range(match.range, in: text) else { continue }
            let matchLower = text.distance(from: text.startIndex, to: matchRange.lowerBound)
            let matchUpper = text.distance(from: text.startIndex, to: matchRange.upperBound)

            // Add preceding text
            if lastEnd < matchRange.lowerBound {
                let preceding = String(text[lastEnd..<matchRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !preceding.isEmpty {
                    segments.append(ContentSegment(
                        id: "text-\(text.distance(from: text.startIndex, to: lastEnd))-\(matchLower)",
                        kind: .text(preceding)
                    ))
                }
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
               let data = Data(base64Encoded: b64.filter { !$0.isWhitespace }, options: .ignoreUnknownCharacters),
               let uiImage = decodeImage(data, "assistant-\(messageId.uuidString)-\(matchLower)-\(matchUpper)") {
                segments.append(ContentSegment(
                    id: "image-\(matchLower)-\(matchUpper)",
                    kind: .image(uiImage)
                ))
            }

            lastEnd = matchRange.upperBound
        }

        // Add remaining text
        if lastEnd < text.endIndex {
            let remaining = String(text[lastEnd...]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !remaining.isEmpty {
                segments.append(ContentSegment(
                    id: "text-\(text.distance(from: text.startIndex, to: lastEnd))-\(text.count)",
                    kind: .text(remaining)
                ))
            }
        }

        return segments.isEmpty
            ? [ContentSegment(id: "text-0-\(text.count)", kind: .text(text))]
            : segments
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
                FontFamily(.custom(LitterFont.markdownFontName))
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
                FontFamily(.custom(LitterFont.markdownFontName))
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
                FontFamily(.custom(LitterFont.markdownFontName))
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
                FontFamily(.custom(LitterFont.markdownFontName))
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
