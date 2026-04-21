import SwiftUI
import UIKit

struct ComputerUseToolCallView: View {
    let data: ConversationMcpToolCallData
    let view: ComputerUseView
    private let externalExpanded: Bool?
    private let onExpandedChange: ((Bool) -> Void)?
    @State private var expanded: Bool
    @State private var a11yExpanded = false
    private let contentFontSize = LitterFont.conversationBodyPointSize

    init(
        data: ConversationMcpToolCallData,
        view: ComputerUseView,
        externalExpanded: Bool? = nil,
        onExpandedChange: ((Bool) -> Void)? = nil
    ) {
        self.data = data
        self.view = view
        self.externalExpanded = externalExpanded
        self.onExpandedChange = onExpandedChange
        _expanded = State(initialValue: externalExpanded ?? (data.status == .failed))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if resolvedExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let screenshot = view.screenshotPng {
                        screenshotPreview(screenshot)
                    }
                    if let error = data.errorMessage, !error.isEmpty {
                        errorBlock(error)
                    }
                    if let text = view.accessibilityText, !text.isEmpty {
                        accessibilityBlock(text)
                    }
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .animation(.spring(duration: 0.32, bounce: 0.12), value: resolvedExpanded)
        .onChange(of: data.status) { _, newStatus in
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
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: toolIcon)
                .litterFont(size: 12, weight: .semibold)
                .foregroundColor(LitterTheme.accent)

            Text(view.summary)
                .litterFont(size: contentFontSize)
                .foregroundColor(LitterTheme.textSystem)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            if let duration = formatDuration(data.durationMs), !duration.isEmpty {
                Text(duration)
                    .litterFont(.caption2)
                    .foregroundColor(durationStatusColor)
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
    }

    @ViewBuilder
    private func screenshotPreview(_ data: Data) -> some View {
        if let image = UIImage(data: data) {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(LitterTheme.border.opacity(0.4), lineWidth: 0.5)
                )
        } else {
            placeholderTile("Screenshot unavailable", tone: LitterTheme.textSecondary)
        }
    }

    private func errorBlock(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ERROR")
                .litterFont(.caption2, weight: .bold)
                .foregroundColor(LitterTheme.danger)
            Text(message)
                .litterFont(size: contentFontSize)
                .foregroundColor(LitterTheme.danger)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func accessibilityBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("ACCESSIBILITY TREE")
                    .litterFont(.caption2, weight: .bold)
                    .foregroundColor(LitterTheme.textSecondary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        a11yExpanded.toggle()
                    }
                } label: {
                    Text(a11yExpanded ? "Collapse" : "Expand")
                        .litterFont(.caption2, weight: .medium)
                        .foregroundColor(LitterTheme.accent)
                }
                .buttonStyle(.plain)
            }

            Text(a11yExpanded ? text : collapsedPreview(text))
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(LitterTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LitterTheme.codeBackground.opacity(0.82))
                )
        }
    }

    private func placeholderTile(_ message: String, tone: Color) -> some View {
        Text(message)
            .litterFont(.caption)
            .foregroundColor(tone)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(LitterTheme.codeBackground.opacity(0.82))
            )
    }

    private func collapsedPreview(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= 6 { return text }
        let head = lines.prefix(6).joined(separator: "\n")
        return "\(head)\n… (\(lines.count - 6) more lines)"
    }

    private var resolvedExpanded: Bool { expanded }

    private func setExpanded(_ newValue: Bool) {
        expanded = newValue
        onExpandedChange?(newValue)
    }

    private var durationStatusColor: Color {
        switch data.status {
        case .failed: return LitterTheme.danger
        case .completed: return LitterTheme.accent
        default: return LitterTheme.textMuted
        }
    }

    private var toolIcon: String {
        switch view.tool {
        case .listApps: return "square.grid.2x2"
        case .getAppState: return "rectangle.on.rectangle"
        case .click: return "cursorarrow.click"
        case .performSecondaryAction: return "ellipsis.circle"
        case .scroll: return "arrow.up.arrow.down"
        case .drag: return "hand.draw"
        case .typeText: return "keyboard"
        case .pressKey: return "command"
        case .setValue: return "textformat.abc"
        case .unknown: return "wand.and.stars"
        }
    }

    private func formatDuration(_ ms: Int?) -> String? {
        guard let ms, ms >= 0 else { return nil }
        if ms < 1000 { return "\(ms)ms" }
        let seconds = Double(ms) / 1000.0
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let mins = Int(seconds / 60)
        let remain = Int(seconds) % 60
        return "\(mins)m \(remain)s"
    }
}
