import SwiftUI
import UIKit

struct ToolCallCardView: View {
    let model: ToolCallCardModel
    let serverId: String?
    private let externalExpanded: Bool?
    private let onExpandedChange: ((Bool) -> Void)?
    @State private var expanded: Bool
    @State private var collapsedDiffSections: Set<String> = []
    private let contentFontSize = LitterFont.conversationBodyPointSize
    private let terminalFontSize: CGFloat = 12

    init(
        model: ToolCallCardModel,
        serverId: String? = nil,
        externalExpanded: Bool? = nil,
        onExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.model = model
        self.serverId = serverId
        self.externalExpanded = externalExpanded
        self.onExpandedChange = onExpandedChange
        _expanded = State(initialValue: externalExpanded ?? model.defaultExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: model.kind.iconName)
                    .litterFont(size: 12, weight: .semibold)
                    .foregroundColor(kindAccent)

                if let attributedSummary = model.attributedSummary {
                    Text(attributedSummary)
                        .litterFont(size: contentFontSize)
                        .lineLimit(1)
                } else {
                    Text(model.summary)
                        .litterFont(size: contentFontSize)
                        .foregroundColor(LitterTheme.textSystem)
                        .lineLimit(1)
                }

                Spacer()

                if let duration = model.duration, !duration.isEmpty {
                    Text(duration)
                        .litterFont(.caption2)
                        .foregroundColor(durationStatusColor)
                        .accessibilityLabel(durationAccessibilityLabel(duration))
                }

                Image(systemName: resolvedExpanded ? "chevron.up" : "chevron.down")
                    .litterFont(size: 11, weight: .medium)
                    .foregroundColor(LitterTheme.textMuted)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) {
                    setExpanded(!resolvedExpanded)
                }
            }

            if resolvedExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    if let imageDescriptor {
                        ToolCallImagePreview(
                            descriptor: imageDescriptor,
                            serverId: serverId
                        )
                    }
                    ForEach(identifiedSections) { section in
                        sectionView(section)
                    }
                }
                .padding(.top, 6)
                .transition(.toolCallDetailReveal)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: resolvedExpanded)
        .onChange(of: model.status) { _, newStatus in
            if newStatus == .failed {
                setExpanded(true)
            }
        }
        .onAppear {
            if let externalExpanded {
                expanded = externalExpanded
            }
        }
        .onChange(of: externalExpanded) { _, newValue in
            if let newValue, newValue != expanded {
                withAnimation(.spring(duration: 0.35, bounce: 0.15)) {
                    expanded = newValue
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setExpanded(_ nextValue: Bool) {
        expanded = nextValue
        if let onExpandedChange {
            onExpandedChange(nextValue)
        }
    }

    private var resolvedExpanded: Bool { expanded }

    private var durationStatusColor: Color {
        switch model.status {
        case .completed:
            return LitterTheme.success
        case .inProgress:
            return LitterTheme.warning
        case .failed:
            return LitterTheme.danger
        case .unknown:
            return LitterTheme.textSecondary
        }
    }

    private func durationAccessibilityLabel(_ duration: String) -> String {
        switch model.status {
        case .completed:
            return "\(duration), completed"
        case .inProgress:
            return "\(duration), in progress"
        case .failed:
            return "\(duration), failed"
        case .unknown:
            return duration
        }
    }

    private var kindAccent: Color {
        switch model.kind {
        case .commandExecution, .commandOutput:
            return LitterTheme.warning
        case .fileChange, .fileDiff, .webSearch:
            return LitterTheme.accent
        case .mcpToolCall, .widget:
            return LitterTheme.accentStrong
        case .mcpToolProgress, .imageView:
            return LitterTheme.warning
        case .collaboration:
            return LitterTheme.success
        }
    }

    @ViewBuilder
    private func sectionView(_ section: IndexedValue<ToolCallSection>) -> some View {
        switch section.value {
        case .kv(let label, let entries):
            if !entries.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(identifiedKeyValueEntries(entries)) { entry in
                            HStack(alignment: .top, spacing: 8) {
                                Text(entry.value.key + ":")
                                    .litterFont(size: contentFontSize, weight: .semibold)
                                    .foregroundColor(LitterTheme.textSecondary)
                                Text(entry.value.value)
                                    .litterFont(size: contentFontSize)
                                    .foregroundColor(LitterTheme.textSystem)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(8)
                    .background(LitterTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        case .code(let label, let language, let content):
            codeLikeSection(label: label, language: language, content: content)
        case .json(let label, let content):
            codeLikeSection(label: label, language: "json", content: content)
        case .diff(let label, let content):
            diffSection(id: section.id, label: label, content: content)
        case .text(let label, let content):
            inlineTextSection(label: label, content: content)
        case .list(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(identifiedTextItems(items, prefix: "list")) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                    .litterFont(size: contentFontSize)
                                    .foregroundColor(LitterTheme.textSecondary)
                                Text(item.value)
                                    .litterFont(size: contentFontSize)
                                    .foregroundColor(LitterTheme.textSystem)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .padding(8)
                    .background(LitterTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        case .progress(let label, let items):
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    sectionLabel(label)
                    VStack(alignment: .leading, spacing: 6) {
                        let identifiedItems = identifiedTextItems(items, prefix: "progress")
                        ForEach(identifiedItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(item.index == identifiedItems.count - 1 ? kindAccent : LitterTheme.textMuted)
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)
                                Text(item.value)
                                    .litterFont(size: contentFontSize)
                                    .foregroundColor(LitterTheme.textSystem)
                                    .textSelection(.enabled)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(8)
                    .background(LitterTheme.surface.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func sectionLabel(_ label: String) -> some View {
        Text(label.uppercased())
            .litterFont(.caption2, weight: .bold)
            .foregroundColor(LitterTheme.textSecondary)
    }

    private func codeLikeSection(label: String, language: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            CodeBlockView(language: language, code: content, fontSize: contentFontSize)
        }
    }

    private func inlineTextSection(label: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel(label)
            Text(verbatim: content)
                .litterMonoFont(size: contentFontSize)
                .foregroundColor(LitterTheme.textBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(LitterTheme.codeBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func diffSection(id: String, label: String, content: String) -> some View {
        let isCollapsible = model.kind == .fileDiff && !label.isEmpty
        let isExpanded = !collapsedDiffSections.contains(id)

        return VStack(alignment: .leading, spacing: 6) {
            if isCollapsible {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        toggleDiffSection(id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        sectionLabel(label)
                        Spacer(minLength: 0)
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .litterFont(size: 10, weight: .medium)
                            .foregroundColor(LitterTheme.textMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            } else if !label.isEmpty {
                sectionLabel(label)
            }

            if isExpanded {
                ScrollView(.horizontal, showsIndicators: true) {
                    SyntaxHighlightedDiffText(
                        diff: content,
                        titleHint: label.isEmpty ? nil : label,
                        fontSize: terminalFontSize
                    )
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(LitterTheme.codeBackground.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    private func toggleDiffSection(_ id: String) {
        if collapsedDiffSections.contains(id) {
            collapsedDiffSections.remove(id)
        } else {
            collapsedDiffSections.insert(id)
        }
    }

    private var identifiedSections: [IndexedValue<ToolCallSection>] {
        let visibleSections = model.sections.filter { section in
            guard model.kind == .imageView else { return true }
            return !sectionContainsInlineImagePayload(section)
        }

        return identifiedValues(visibleSections, prefix: "section") { section in
            switch section {
            case .kv(let label, let entries):
                return "\(label)|kv|\(entries.map { "\($0.key)=\($0.value)" }.joined(separator: "|"))"
            case .code(let label, let language, let content):
                return "\(label)|code|\(language)|\(content)"
            case .json(let label, let content):
                return "\(label)|json|\(content)"
            case .diff(let label, let content):
                return "\(label)|diff|\(content)"
            case .text(let label, let content):
                return "\(label)|text|\(content)"
            case .list(let label, let items):
                return "\(label)|list|\(items.joined(separator: "|"))"
            case .progress(let label, let items):
                return "\(label)|progress|\(items.joined(separator: "|"))"
            }
        }
    }

    private var imageDescriptor: ToolCallImageDescriptor? {
        guard model.kind == .imageView else { return nil }

        for section in model.sections {
            switch section {
            case .kv(_, let entries):
                for entry in entries {
                    if let descriptor = imageDescriptor(from: entry.value) {
                        return descriptor
                    }
                }
            case .code(_, _, let content),
                 .json(_, let content),
                 .text(_, let content):
                if let descriptor = imageDescriptor(from: content) {
                    return descriptor
                }
            default:
                continue
            }
        }

        return nil
    }

    private func sectionContainsInlineImagePayload(_ section: ToolCallSection) -> Bool {
        switch section {
        case .code(_, _, let content),
             .json(_, let content),
             .text(_, let content):
            return Self.inlineImageData(from: content) != nil
        default:
            return false
        }
    }

    private func imageDescriptor(from rawValue: String) -> ToolCallImageDescriptor? {
        if let data = Self.inlineImageData(from: rawValue) {
            return .inlineData(data)
        }
        if let path = Self.normalizedImagePath(from: rawValue) {
            return .filePath(path)
        }
        return nil
    }

    private static func normalizedImagePath(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            return url.path(percentEncoded: false)
        }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~/") || trimmed.hasPrefix("\\\\") {
            return trimmed
        }
        if trimmed.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil {
            return trimmed
        }

        return nil
    }

    private static func inlineImageData(from rawValue: String) -> Data? {
        guard let match = rawValue.range(
            of: #"data:image/[^;]+;base64,[A-Za-z0-9+/=\s]+"#,
            options: .regularExpression
        ) else {
            return nil
        }

        let source = String(rawValue[match]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let commaIndex = source.firstIndex(of: ",") else { return nil }
        let base64 = String(source[source.index(after: commaIndex)...])
        return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
    }

    private func identifiedKeyValueEntries(_ entries: [ToolCallKeyValue]) -> [IndexedValue<ToolCallKeyValue>] {
        identifiedValues(entries, prefix: "kv") { entry in
            "\(entry.key)|\(entry.value)"
        }
    }

    private func identifiedTextItems(_ values: [String], prefix: String) -> [IndexedValue<String>] {
        identifiedValues(values, prefix: prefix) { $0 }
    }

    private func identifiedValues<Value>(
        _ values: [Value],
        prefix: String,
        key: (Value) -> String
    ) -> [IndexedValue<Value>] {
        var seen: [String: Int] = [:]
        return values.enumerated().map { index, value in
            let signature = key(value)
            let occurrence = seen[signature, default: 0]
            seen[signature] = occurrence + 1
            return IndexedValue(
                id: "\(prefix)-\(signature.hashValue)-\(occurrence)",
                index: index,
                value: value
            )
        }
    }
}

private extension AnyTransition {
    static var toolCallDetailReveal: AnyTransition { .sectionReveal }
}

private struct IndexedValue<Value>: Identifiable {
    let id: String
    let index: Int
    let value: Value
}

private enum ToolCallImageDescriptor: Equatable {
    case inlineData(Data)
    case filePath(String)

    var cacheKey: String {
        switch self {
        case .inlineData(let data):
            return "inline-\(data.hashValue)"
        case .filePath(let path):
            return "path-\(path)"
        }
    }
}

private struct ToolCallImagePreview: View {
    @Environment(AppModel.self) private var appModel

    let descriptor: ToolCallImageDescriptor
    let serverId: String?

    @State private var renderedImage: UIImage?
    @State private var isLoading = false
    @State private var loadError: String?

    private static let imageCache = NSCache<NSString, UIImage>()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("IMAGE")
                .litterFont(.caption2, weight: .bold)
                .foregroundColor(LitterTheme.textSecondary)

            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LitterTheme.codeBackground.opacity(0.82))

                if let renderedImage {
                    Image(uiImage: renderedImage)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .draggable(Image(uiImage: renderedImage)) {
                            Image(uiImage: renderedImage)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 120)
                        }
                } else if isLoading {
                    ProgressView()
                        .tint(LitterTheme.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    Text(loadError ?? "Image unavailable")
                        .litterFont(.caption)
                        .foregroundColor(loadError == nil ? LitterTheme.textSecondary : LitterTheme.danger)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .task(id: taskKey) {
            await loadImage()
        }
    }

    private var taskKey: String {
        "\(descriptor.cacheKey)|\(serverId ?? "<none>")"
    }

    private func loadImage() async {
        if let cached = Self.imageCache.object(forKey: taskKey as NSString) {
            renderedImage = cached
            loadError = nil
            isLoading = false
            return
        }

        isLoading = true
        loadError = nil

        defer {
            isLoading = false
        }

        do {
            let image: UIImage
            switch descriptor {
            case .inlineData(let data):
                guard let decoded = UIImage(data: data) else {
                    throw ToolCallImageError.invalidImageData
                }
                image = decoded
            case .filePath(let path):
                let data = try await fetchImageData(path: path)
                guard let decoded = UIImage(data: data) else {
                    throw ToolCallImageError.invalidImageData
                }
                image = decoded
            }

            Self.imageCache.setObject(image, forKey: taskKey as NSString)
            renderedImage = image
            loadError = nil
        } catch {
            renderedImage = nil
            loadError = ToolCallImageError.message(for: error)
        }
    }

    private func fetchImageData(path: String) async throws -> Data {
        let resolved = try await appModel.client.resolveImageView(
            serverId: serverId ?? "",
            path: path
        )
        return Data(resolved.bytes)
    }
}

private enum ToolCallImageError: LocalizedError {
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidImageData:
            return "Could not decode the image."
        }
    }

    static func message(for error: Error) -> String {
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Image unavailable" : message
    }
}

#if DEBUG
#Preview("Tool Call Card") {
    ZStack {
        LitterTheme.backgroundGradient.ignoresSafeArea()
        ToolCallCardView(model: LitterPreviewData.sampleToolCallModel)
            .padding(20)
    }
}
#endif
