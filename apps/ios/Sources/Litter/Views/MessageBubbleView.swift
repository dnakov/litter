import SwiftUI
import Textual
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
    let markdownString: String
    let markdownIdentity: Int
    var label: String? = nil
    var textScale: CGFloat = 1.0
    var compact: Bool = false
    var themeVersion: Int = 0
    @ScaledMetric(relativeTo: .body) private var mdBodySize: CGFloat = 14
    @ScaledMetric(relativeTo: .footnote) private var mdCodeSize: CGFloat = 13

    private var bodySize: CGFloat { (compact ? 12 : mdBodySize) * textScale }
    private var codeSize: CGFloat { (compact ? 11 : mdCodeSize) * textScale }

    init(
        text: String,
        label: String? = nil,
        textScale: CGFloat = 1.0,
        compact: Bool = false,
        themeVersion: Int = 0
    ) {
        self.markdownString = text
        self.markdownIdentity = text.hashValue
        self.label = label
        self.textScale = textScale
        self.compact = compact
        self.themeVersion = themeVersion
    }

    init(
        markdownString: String,
        markdownIdentity: Int,
        label: String? = nil,
        textScale: CGFloat = 1.0,
        compact: Bool = false,
        themeVersion: Int = 0
    ) {
        self.markdownString = markdownString
        self.markdownIdentity = markdownIdentity
        self.label = label
        self.textScale = textScale
        self.compact = compact
        self.themeVersion = themeVersion
    }

    static func == (lhs: AssistantBubble, rhs: AssistantBubble) -> Bool {
        lhs.markdownIdentity == rhs.markdownIdentity &&
        lhs.label == rhs.label &&
        lhs.textScale == rhs.textScale &&
        lhs.compact == rhs.compact &&
        lhs.themeVersion == rhs.themeVersion
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: compact ? 4 : 8) {
                if let label {
                    Text(label)
                        .font(LitterFont.styled(.caption2, weight: .semibold, scale: textScale))
                        .foregroundColor(LitterTheme.textSecondary)
                }
                StructuredText(markdown: markdownString)
                    .font(.custom(LitterFont.markdownFontName, size: bodySize))
                    .foregroundStyle(LitterTheme.textBody)
                    .textual.structuredTextStyle(LitterStructuredStyle(bodySize: bodySize, codeSize: codeSize))
                    .textual.textSelection(.enabled)
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
    var themeVersion: Int = 0
    var onSnapshotRendered: (() -> Void)? = nil
    @State private var renderedText: String = ""
    @State private var pendingText: String?
    @State private var flushWorkItem: DispatchWorkItem?
    @State private var snapshotOpacity: Double = 1.0

    private let flushInterval: TimeInterval = 0.06

    var body: some View {
        AssistantBubble(
            markdownString: renderedText,
            markdownIdentity: renderedText.hashValue,
            label: label,
            textScale: textScale,
            themeVersion: themeVersion
        )
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
    private let renderCache = MessageRenderCache.shared
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
        .enableInjection()
    }

    private var renderRevisionKey: MessageRenderCache.RevisionKey {
        MessageRenderCache.makeRevisionKey(
            for: message,
            serverId: serverId,
            agentDirectoryVersion: agentDirectoryVersion,
            isStreaming: isStreamingMessage
        )
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
                if let first = parsed.first,
                   case let .markdown(content, identity) = first.kind {
                    AssistantBubble(
                        markdownString: content,
                        markdownIdentity: identity,
                        label: assistantAgentLabel,
                        textScale: textScale
                    )
                } else {
                    AssistantBubble(text: message.text, label: assistantAgentLabel, textScale: textScale)
                }
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
                            case .markdown(let content, _):
                                StructuredText(markdown: content)
                                    .font(.custom(LitterFont.markdownFontName, size: mdBodySize * textScale))
                                    .foregroundStyle(LitterTheme.textBody)
                                    .textual.structuredTextStyle(LitterStructuredStyle(bodySize: mdBodySize * textScale, codeSize: mdCodeSize * textScale))
                                    .textual.textSelection(.enabled)
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
                onMessage: handleWidgetMessage,
                textScale: textScale
            )
        } else {
            let parsed = systemParseResultForRendering
            switch parsed {
            case .recognized(let model):
                ToolCallCardView(model: model, textScale: textScale)
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
                    .font(.system(size: 11 * textScale, weight: .semibold))
                    .foregroundColor(LitterTheme.accent)
                Text(displayTitle.uppercased())
                    .font(LitterFont.styled(.caption2, weight: .bold, scale: textScale))
                    .foregroundColor(LitterTheme.accent)
                Spacer()
            }

            if !markdown.isEmpty {
                StructuredText(markdown: markdown)
                    .font(.custom(LitterFont.markdownFontName, size: mdSystemBodySize * textScale))
                    .foregroundStyle(LitterTheme.textSystem)
                    .textual.structuredTextStyle(LitterSystemStructuredStyle(bodySize: mdSystemBodySize * textScale, codeSize: mdSystemCodeSize * textScale))
                    .textual.textSelection(.enabled)
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

    private var assistantSegmentsForRendering: [MessageRenderCache.AssistantSegment] {
        renderCache.assistantSegments(
            for: message,
            key: renderRevisionKey
        )
    }

    private var systemParseResultForRendering: ToolCallParseResult {
        renderCache.systemParseResult(
            for: message,
            key: renderRevisionKey,
            resolveTargetLabel: resolveTargetLabel
        )
    }
}

// MARK: - Litter Textual Styles

struct LitterHeadingStyle: StructuredText.HeadingStyle {
    let fontScales: [CGFloat]
    let topMargins: [CGFloat]
    let bottomMargins: [CGFloat]

    func makeBody(configuration: Configuration) -> some View {
        let level = min(configuration.headingLevel, 3) - 1
        let scale = level < fontScales.count ? fontScales[level] : 1.0
        let top = level < topMargins.count ? topMargins[level] : 8
        let bottom = level < bottomMargins.count ? bottomMargins[level] : 4

        configuration.label
            .textual.fontScale(scale)
            .fontWeight(level == 0 ? .bold : .semibold)
            .foregroundStyle(LitterTheme.textPrimary)
            .textual.blockSpacing(.init(top: top, bottom: bottom))
    }
}

struct LitterBlockQuoteStyle: StructuredText.BlockQuoteStyle {
    let topBottom: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(LitterTheme.textSecondary)
            .italic()
            .padding(.leading, 12)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(LitterTheme.border)
                    .frame(width: 3)
            }
            .textual.blockSpacing(.init(top: topBottom, bottom: topBottom))
    }
}

struct LitterCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            configuration.label
                .monospaced()
                .textual.textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LitterTheme.codeBackground.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(GlassRectModifier(cornerRadius: 8))
        .textual.blockSpacing(.init(top: 8, bottom: 8))
    }
}

struct LitterSystemCodeBlockStyle: StructuredText.CodeBlockStyle {
    func makeBody(configuration: Configuration) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            configuration.label
                .monospaced()
                .textual.textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(LitterTheme.codeBackground.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .modifier(GlassRectModifier(cornerRadius: 8))
        .textual.blockSpacing(.init(top: 6, bottom: 6))
    }
}

struct LitterThematicBreakStyle: StructuredText.ThematicBreakStyle {
    let topBottom: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Divider()
            .overlay(LitterTheme.border)
            .textual.blockSpacing(.init(top: topBottom, bottom: topBottom))
    }
}

struct LitterListItemStyle: StructuredText.ListItemStyle {
    let topBottom: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .top, spacing: 8) {
            configuration.marker
            configuration.block
        }
        .textual.blockSpacing(.init(top: topBottom, bottom: topBottom))
    }
}

struct LitterStructuredStyle: StructuredText.Style {
    let bodySize: CGFloat
    let codeSize: CGFloat

    var inlineStyle: InlineStyle {
        InlineStyle()
            .code(
                .monospaced,
                .fontScale(codeSize / bodySize),
                .foregroundColor(LitterTheme.accent),
                .backgroundColor(LitterTheme.surface)
            )
            .strong(.fontWeight(.semibold), .foregroundColor(LitterTheme.textPrimary))
            .emphasis(.italic)
            .link(.foregroundColor(LitterTheme.accent))
    }

    var headingStyle: LitterHeadingStyle {
        LitterHeadingStyle(
            fontScales: [1.43, 1.21, 1.07],
            topMargins: [16, 12, 10],
            bottomMargins: [8, 6, 4]
        )
    }

    var paragraphStyle: StructuredText.DefaultParagraphStyle { .default }

    var blockQuoteStyle: LitterBlockQuoteStyle {
        LitterBlockQuoteStyle(topBottom: 8)
    }

    var codeBlockStyle: LitterCodeBlockStyle {
        LitterCodeBlockStyle()
    }

    var listItemStyle: LitterListItemStyle {
        LitterListItemStyle(topBottom: 4)
    }

    var unorderedListMarker: StructuredText.SymbolListMarker { .disc }
    var orderedListMarker: StructuredText.DecimalListMarker { .decimal }
    var tableStyle: StructuredText.DefaultTableStyle { .default }
    var tableCellStyle: StructuredText.DefaultTableCellStyle { .default }

    var thematicBreakStyle: LitterThematicBreakStyle {
        LitterThematicBreakStyle(topBottom: 12)
    }
}

struct LitterSystemStructuredStyle: StructuredText.Style {
    let bodySize: CGFloat
    let codeSize: CGFloat

    var inlineStyle: InlineStyle {
        InlineStyle()
            .code(
                .monospaced,
                .fontScale(codeSize / bodySize),
                .foregroundColor(LitterTheme.accent),
                .backgroundColor(LitterTheme.surface)
            )
            .strong(.fontWeight(.semibold), .foregroundColor(LitterTheme.textPrimary))
            .emphasis(.italic)
            .link(.foregroundColor(LitterTheme.accent))
    }

    var headingStyle: LitterHeadingStyle {
        LitterHeadingStyle(
            fontScales: [1.31, 1.15, 1.08],
            topMargins: [12, 10, 8],
            bottomMargins: [6, 4, 4]
        )
    }

    var paragraphStyle: StructuredText.DefaultParagraphStyle { .default }

    var blockQuoteStyle: LitterBlockQuoteStyle {
        LitterBlockQuoteStyle(topBottom: 6)
    }

    var codeBlockStyle: LitterSystemCodeBlockStyle {
        LitterSystemCodeBlockStyle()
    }

    var listItemStyle: LitterListItemStyle {
        LitterListItemStyle(topBottom: 3)
    }

    var unorderedListMarker: StructuredText.SymbolListMarker { .disc }
    var orderedListMarker: StructuredText.DecimalListMarker { .decimal }
    var tableStyle: StructuredText.DefaultTableStyle { .default }
    var tableCellStyle: StructuredText.DefaultTableCellStyle { .default }

    var thematicBreakStyle: LitterThematicBreakStyle {
        LitterThematicBreakStyle(topBottom: 8)
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
