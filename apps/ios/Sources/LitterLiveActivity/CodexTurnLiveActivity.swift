import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Colors

private let amberColor   = LitterPalette.amber
private let dangerColor  = LitterPalette.dangerFixed

struct CodexTurnLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: CodexTurnAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    litterLogo(size: 18)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(context.attributes.prompt)
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        HStack(spacing: 6) {
                            phaseBadge(context.state)
                            if context.state.toolCallCount > 0 {
                                Label("\(context.state.toolCallCount)", systemImage: "chevron.left.forwardslash.chevron.right")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            if context.state.fileChangeCount > 0 {
                                Label("\(context.state.fileChangeCount)", systemImage: "doc.text")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.3))
                            }
                            if context.state.contextPercent > 0 {
                                ctxBadge(context.state.contextPercent)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    liveTimer(context: context, size: 11)
                        .foregroundStyle(.white.opacity(0.4))
                }
            } compactLeading: {
                litterLogo(size: 16)
            } compactTrailing: {
                liveTimer(context: context, size: 12)
                    .foregroundStyle(.white.opacity(0.5))
            } minimal: {
                litterLogo(size: 16)
            }
        }
    }

    // MARK: - Lock Screen

    private func lockScreenView(context: ActivityViewContext<CodexTurnAttributes>) -> some View {
        LockScreenCardView(
            prompt: context.attributes.prompt,
            model: context.attributes.model,
            cwd: context.attributes.cwd,
            state: context.state,
            timerContent: AnyView(
                liveTimer(context: context, size: 15)
                    .fontWeight(.regular)
                    .foregroundStyle(isActive(context.state) ? .white.opacity(0.7) : .white.opacity(0.45))
            )
        )
    }

    // MARK: - Components

    private func litterLogo(size: CGFloat) -> some View {
        Image("brand_logo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private func displayText(_ state: CodexTurnAttributes.ContentState) -> String {
        if let snippet = state.outputSnippet, !snippet.isEmpty {
            return snippet
        }
        return statusText(state)
    }

    private func snippetColor(_ state: CodexTurnAttributes.ContentState) -> Color {
        if state.outputSnippet != nil {
            return .white.opacity(0.35)
        }
        switch state.phase {
        case .thinking, .toolCall: return amberColor.opacity(0.6)
        case .completed: return .white.opacity(0.35)
        case .failed: return dangerColor.opacity(0.6)
        }
    }

    private func phaseBadge(_ state: CodexTurnAttributes.ContentState) -> some View {
        Text(phaseBadgeText(state))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(phaseColor(state))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(phaseBgColor(state))
            )
    }

    private func metaChip(systemImage: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.25))
            Text(text)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.white.opacity(0.3))
                .lineLimit(1)
        }
        .padding(.trailing, 10)
    }

    private func ctxBadge(_ percent: Int) -> some View {
        Text("\(percent)%")
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(ctxColor(percent))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(ctxBgColor(percent))
            )
    }

    @ViewBuilder
    private func liveTimer(context: ActivityViewContext<CodexTurnAttributes>, size: CGFloat) -> some View {
        if isActive(context.state) {
            Text(timerInterval: context.attributes.startDate...Date.distantFuture, countsDown: false)
                .font(.system(size: size, design: .monospaced))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(formatElapsed(context.state.elapsedSeconds))
                .font(.system(size: size, design: .monospaced))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Helpers

    private func isActive(_ state: CodexTurnAttributes.ContentState) -> Bool {
        state.phase == .thinking || state.phase == .toolCall
    }

    private func statusText(_ state: CodexTurnAttributes.ContentState) -> String {
        switch state.phase {
        case .thinking: return "Thinking..."
        case .toolCall: return state.toolName ?? "Running tool..."
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }

    private func phaseBadgeText(_ state: CodexTurnAttributes.ContentState) -> String {
        switch state.phase {
        case .thinking: return "thinking"
        case .toolCall: return "tool"
        case .completed: return "done"
        case .failed: return "failed"
        }
    }

    private func phaseColor(_ state: CodexTurnAttributes.ContentState) -> Color {
        switch state.phase {
        case .thinking, .toolCall: return amberColor
        case .completed: return .white.opacity(0.5)
        case .failed: return dangerColor
        }
    }

    private func phaseBgColor(_ state: CodexTurnAttributes.ContentState) -> Color {
        switch state.phase {
        case .thinking, .toolCall: return amberColor.opacity(0.12)
        case .completed: return .white.opacity(0.06)
        case .failed: return dangerColor.opacity(0.12)
        }
    }

    private func ctxColor(_ percent: Int) -> Color {
        if percent >= 80 { return dangerColor }
        if percent >= 60 { return amberColor }
        return .white.opacity(0.35)
    }

    private func ctxBgColor(_ percent: Int) -> Color {
        if percent >= 80 { return dangerColor.opacity(0.1) }
        if percent >= 60 { return amberColor.opacity(0.1) }
        return .white.opacity(0.05)
    }

    private func formatElapsed(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }

}
