import SwiftUI
import MarkdownUI
import Inject

// MARK: - Reusable bubble components

struct UserBubble: View {
    let text: String
    var images: [ChatImage] = []
    var textScale: CGFloat = 1.0
    var compact: Bool = false

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: compact ? 30 : 60)
            VStack(alignment: .trailing, spacing: compact ? 4 : 8) {
                ForEach(images) { img in
                    if let uiImage = UserBubble.decodeImage(from: img.data, cacheKey: "user-\(img.id.uuidString)") {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 200, maxHeight: 200)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                if !text.isEmpty {
                    Text(text)
                        .font(LitterFont.styled(compact ? .footnote : .callout, scale: textScale))
                        .foregroundColor(LitterTheme.textPrimary)
                        .textSelection(.enabled)
                }
            }
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 10)
            .modifier(GlassRectModifier(cornerRadius: compact ? 10 : 14, tint: LitterTheme.accent.opacity(0.3)))
        }
    }

    private static let imageCache = NSCache<NSString, UIImage>()

    private static func decodeImage(from data: Data, cacheKey: String) -> UIImage? {
        let key = cacheKey as NSString
        if let cached = imageCache.object(forKey: key) { return cached }
        guard let image = UIImage(data: data) else { return nil }
        imageCache.setObject(image, forKey: key)
        return image
    }
}

struct AssistantBubble: View, Equatable {
    let text: String
    var label: String? = nil
    var textScale: CGFloat = 1.0
    var compact: Bool = false
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13

    private var bodySize: CGFloat { (compact ? 12 : mdBodySize) * textScale }
    private var codeSize: CGFloat { (compact ? 11 : mdCodeSize) * textScale }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.text == rhs.text &&
        lhs.label == rhs.label &&
        lhs.textScale == rhs.textScale &&
        lhs.compact == rhs.compact
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                if let label {
                    Text(label)
                        .font(LitterFont.styled(.caption2, weight: .semibold, scale: textScale))
                        .foregroundColor(LitterTheme.textSecondary)
                }
                Markdown(text)
                    .markdownTheme(.litter(bodySize: bodySize, codeSize: codeSize))
                    .markdownCodeSyntaxHighlighter(.plain)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: compact ? 8 : 20)
        }
    }
}

struct StreamingAssistantBubble: View {
    let text: String
    var label: String? = nil
    var textScale: CGFloat = 1.0
    var onSnapshotRendered: (() -> Void)? = nil
    @State private var renderedText: String = ""
    @State private var pendingText: String?
    @State private var flushWorkItem: DispatchWorkItem?
    @State private var snapshotOpacity: Double = 1.0

    private let flushInterval: TimeInterval = 0.06

    var body: some View {
        AssistantBubble(text: renderedText, label: label, textScale: textScale)
            .equatable()
            .opacity(snapshotOpacity)
            .onAppear {
                renderedText = text
                onSnapshotRendered?()
            }
            .onChange(of: text) {
                scheduleRenderUpdate(with: text)
            }
            .onDisappear {
                flushWorkItem?.cancel()
                flushWorkItem = nil
                pendingText = nil
                snapshotOpacity = 1.0
            }
    }

    private func scheduleRenderUpdate(with newText: String) {
        guard newText != renderedText else { return }
        if renderedText.isEmpty {
            renderedText = newText
            return
        }

        pendingText = newText
        guard flushWorkItem == nil else { return }
        scheduleFlush()
    }

    private func scheduleFlush() {
        let work = DispatchWorkItem {
            flushWorkItem = nil
            guard let pendingText else { return }
            renderedText = pendingText
            self.pendingText = nil
            animateSnapshotArrival()
            onSnapshotRendered?()
        }

        flushWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func animateSnapshotArrival() {
        snapshotOpacity = 0.94
        withAnimation(.easeOut(duration: 0.14)) {
            snapshotOpacity = 1.0
        }
    }
}

// MARK: - Full message bubble (used in conversation)

struct MessageBubbleView: View {
    @ObserveInjection var inject
    let message: ChatMessage
    let serverId: String?
    let agentDirectoryVersion: Int
    let textScale: CGFloat
    let isStreamingMessage: Bool
    let actionsDisabled: Bool
    let onStreamingSnapshotRendered: (() -> Void)?
    let resolveTargetLabel: ((String) -> String?)?
    let onWidgetPrompt: ((String) -> Void)?
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
        serverId: String? = nil,
        agentDirectoryVersion: Int = 0,
        textScale: CGFloat = 1.0,
        isStreamingMessage: Bool = false,
        actionsDisabled: Bool = false,
        onStreamingSnapshotRendered: (() -> Void)? = nil,
        resolveTargetLabel: ((String) -> String?)? = nil,
        onWidgetPrompt: ((String) -> Void)? = nil,
        onEditUserMessage: ((ChatMessage) -> Void)? = nil,
        onForkFromUserMessage: ((ChatMessage) -> Void)? = nil
    ) {
        self.message = message
        self.serverId = serverId
        self.agentDirectoryVersion = agentDirectoryVersion
        self.textScale = textScale
        self.isStreamingMessage = isStreamingMessage
        self.actionsDisabled = actionsDisabled
        self.onStreamingSnapshotRendered = onStreamingSnapshotRendered
        self.resolveTargetLabel = resolveTargetLabel
        self.onWidgetPrompt = onWidgetPrompt
        self.onEditUserMessage = onEditUserMessage
        self.onForkFromUserMessage = onForkFromUserMessage
    }

    var body: some View {
        Group {
            if message.role == .user {
                userBubbleWithActions
            } else if message.role == .assistant {
                assistantContent
            } else if isReasoning {
                HStack(alignment: .top, spacing: 0) {
                    reasoningContent
                    Spacer(minLength: 20)
                }
            } else {
                HStack(alignment: .top, spacing: 0) {
                    systemBubble
                    Spacer(minLength: 20)
                }
            }
        }
        .task(id: parseRefreshToken) {
            prepareDerivedContent()
        }
        .enableInjection()
    }

    private var parseRefreshToken: String {
        let contentToken = isStreamingMessage ? "streaming" : String(message.text.hashValue)
        return "\(message.id.uuidString)-\(message.role)-\(contentToken)-\(message.images.count)-\(serverId ?? "<nil>")-\(agentDirectoryVersion)"
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

    private var userBubbleWithActions: some View {
        UserBubble(text: message.text, images: message.images, textScale: textScale)
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

    @ViewBuilder
    private var assistantContent: some View {
        if isStreamingMessage {
            StreamingAssistantBubble(
                text: message.text,
                label: assistantAgentLabel,
                textScale: textScale,
                onSnapshotRendered: onStreamingSnapshotRendered
            )
        } else {
            let parsed = assistantSegmentsForRendering
            let hasImages = parsed.contains { if case .image = $0.kind { return true } else { return false } }

            if !hasImages {
                // Simple text-only path — use the reusable AssistantBubble
                AssistantBubble(text: message.text, label: assistantAgentLabel, textScale: textScale)
            } else {
                // Inline images — need segment-based rendering
                HStack(alignment: .top, spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let assistantLabel = assistantAgentLabel {
                            Text(assistantLabel)
                                .font(LitterFont.styled(.caption2, weight: .semibold, scale: textScale))
                                .foregroundColor(LitterTheme.textSecondary)
                        }
                        ForEach(parsed) { segment in
                            switch segment.kind {
                            case .text(let md):
                                Markdown(md)
                                    .markdownTheme(.litter(bodySize: mdBodySize * textScale, codeSize: mdCodeSize * textScale))
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
                    Spacer(minLength: 20)
                }
            }
        }
    }

    private var assistantAgentLabel: String? {
        AgentLabelFormatter.format(
            nickname: message.agentNickname,
            role: message.agentRole
        )
    }

    private var reasoningContent: some View {
        let (_, body) = extractSystemTitleAndBody(message.text)
        return Text(normalizedReasoningText(body))
            .font(LitterFont.styled(.footnote, scale: textScale))
            .italic()
            .foregroundColor(LitterTheme.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var systemBubble: some View {
        if let widget = message.widgetState {
            WidgetContainerView(
                widget: widget,
                onMessage: handleWidgetMessage
            )
        } else {
            let parsed = systemParseResultForRendering
            switch parsed {
            case .recognized(let model):
                ToolCallCardView(model: model)
            case .unrecognized:
                genericSystemBubble
            }
        }
    }

    private func handleWidgetMessage(_ body: Any) {
        guard let dict = body as? [String: Any],
              let type = dict["_type"] as? String else { return }
        switch type {
        case "sendPrompt":
            if let text = dict["text"] as? String, !text.isEmpty {
                onWidgetPrompt?(text)
            }
        case "openLink":
            if let urlStr = dict["url"] as? String, let url = URL(string: urlStr) {
                UIApplication.shared.open(url)
            }
        default:
            break
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
                    .font(LitterFont.styled(.caption2, weight: .bold, scale: textScale))
                    .foregroundColor(LitterTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                Markdown(markdown)
                    .markdownTheme(.litterSystem(bodySize: mdSystemBodySize * textScale, codeSize: mdSystemCodeSize * textScale))
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

    private func normalizedReasoningText(_ body: String) -> String {
        body
            .components(separatedBy: .newlines)
            .map { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("**"), trimmed.hasSuffix("**"), trimmed.count > 4 {
                    return String(trimmed.dropFirst(2).dropLast(2))
                }
                return line
            }
            .joined(separator: "\n")
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
        return ToolCallMessageParser.parse(
            message: message,
            resolveTargetLabel: resolveTargetLabel
        )
    }

    private func prepareDerivedContent() {
        switch message.role {
        case .assistant:
            guard !isStreamingMessage else {
                didPrepareAssistantSegments = false
                didPrepareSystemResult = false
                return
            }
            parsedAssistantSegments = Self.extractInlineSegments(
                from: message.text,
                messageId: message.id,
                decodeImage: decodedImage(from:cacheKey:)
            )
            didPrepareAssistantSegments = true
            didPrepareSystemResult = false
        case .system:
            parsedSystemResult = ToolCallMessageParser.parse(
                message: message,
                resolveTargetLabel: resolveTargetLabel
            )
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
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.21)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.07)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(LitterTheme.textPrimary)
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
                    code: configuration.content,
                    fontSize: codeSize
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
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.15)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 10, bottom: 4)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(bodySize * 1.08)
                        ForegroundColor(LitterTheme.textPrimary)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .strong {
                FontWeight(.semibold)
                ForegroundColor(LitterTheme.textPrimary)
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
                    code: configuration.content,
                    fontSize: codeSize
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

#if DEBUG
#Preview("Message Bubbles") {
    LitterPreviewScene {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(LitterPreviewData.sampleMessages) { message in
                    MessageBubbleView(
                        message: message,
                        serverId: LitterPreviewData.sampleServer.id
                    )
                }
            }
            .padding(16)
        }
    }
}
#endif
