import SwiftUI

private struct LoadingStageText: View {
    private static let stages: [String] = [
        "Choosing archetype…",
        "Sketching sprites…",
        "Scattering hazards…",
        "Tuning physics…",
        "Wiring up controls…",
        "Launching…",
    ]
    @State private var index = 0

    var body: some View {
        Text(Self.stages[index])
            .litterFont(.caption, weight: .medium)
            .foregroundStyle(LitterTheme.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
            .id(index)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    if Task.isCancelled { return }
                    await MainActor.run {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            index = (index + 1) % Self.stages.count
                        }
                    }
                }
            }
    }
}

struct MinigameOverlayView: View {
    let state: MinigameOverlayState
    let onClose: () -> Void
    let onRetry: () -> Void

    @State private var skeletonShimmer: CGFloat = -1

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(LitterTheme.textSecondary.opacity(0.2))
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(LitterTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(LitterTheme.textSecondary.opacity(0.15), lineWidth: 0.5)
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: -4)
    }

    private var titleText: String {
        switch state {
        case .idle: return ""
        case .loading: return "Generating…"
        case .shown(let content): return content.title
        case .failed: return "Couldn't generate"
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(titleText)
                .litterFont(.caption, weight: .medium)
                .foregroundStyle(LitterTheme.textSecondary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LitterTheme.textSecondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close minigame")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle:
            EmptyView()
        case .loading:
            loadingSkeleton
        case .shown(let game):
            WidgetWebView(
                widgetHTML: game.html,
                isFinalized: true,
                isMinigame: true
            )
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
        case .failed(let message):
            failureCard(message: message)
        }
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 14) {
            LoadingStageText()
            shimmerBar(height: 96)
            shimmerBar(height: 14)
                .frame(maxWidth: 220)
        }
        .padding(20)
    }

    private func shimmerBar(height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(LinearGradient(
                colors: [
                    LitterTheme.textSecondary.opacity(0.18),
                    LitterTheme.accent.opacity(0.4),
                    LitterTheme.textSecondary.opacity(0.18),
                ],
                startPoint: UnitPoint(x: skeletonShimmer - 0.3, y: 0.5),
                endPoint: UnitPoint(x: skeletonShimmer + 0.3, y: 0.5)
            ))
            .frame(height: height)
            .animation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false), value: skeletonShimmer)
            .onAppear { skeletonShimmer = 2 }
    }

    private func failureCard(message: String) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text("Couldn't generate a minigame.")
                .litterFont(.body, weight: .medium)
                .foregroundStyle(LitterTheme.textPrimary)
            Text(message)
                .litterFont(.caption)
                .foregroundStyle(LitterTheme.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
            Button(action: onRetry) {
                Text("Try again")
                    .litterFont(.caption, weight: .semibold)
                    .foregroundStyle(LitterTheme.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .overlay(
                        Capsule().stroke(LitterTheme.accent.opacity(0.5), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
