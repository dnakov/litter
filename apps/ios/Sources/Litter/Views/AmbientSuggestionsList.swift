import SwiftUI

/// A reusable list of ambient suggestion rows shared between the iPad hero
/// (`NewThreadHeroView`) and the iPhone home composer (`HomeDashboardView`).
///
/// Each suggestion renders as its own liquid-glass capsule button (matching
/// the style of `HomeModelChip` / `ProjectChip` / `ServerPill`). Titles are
/// shown single-line with truncation so the pills stay pill-shaped; the
/// longer prompt body is passed back on tap rather than shown here.
///
/// On appear / whenever the suggestion IDs change, pills stagger in — each
/// pill rises from slightly below into place, with a ~140ms delay between
/// adjacent pills so they visually stack up on top of each other.
struct AmbientSuggestionsList: View {
    let suggestions: [AmbientSuggestion]
    let onTap: (AmbientSuggestion) -> Void
    /// Maximum number of pills to display.
    var cap: Int = 4

    /// Number of pills currently visible, counted from the BOTTOM of the
    /// stack. The last pill (highest index) reveals first and each pill
    /// above it follows, so they visually stack up onto each other.
    @State private var revealedCount: Int = 0

    private var visible: [AmbientSuggestion] {
        Array(suggestions.prefix(cap))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(visible.enumerated()), id: \.element.id) { index, suggestion in
                // Reveal from the bottom up: the bottom pill (index == count-1)
                // is visible as soon as `revealedCount >= 1`, then the pill
                // above, and so on — so pills visually stack upward.
                let revealed = (visible.count - index) <= revealedCount
                pill(for: suggestion)
                    .opacity(revealed ? 1 : 0)
                    .offset(y: revealed ? 0 : 14)
            }
        }
        .task(id: visible.map(\.id)) {
            revealedCount = 0
            for i in visible.indices {
                withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                    revealedCount = i + 1
                }
                try? await Task.sleep(nanoseconds: 140_000_000)
            }
        }
    }

    @ViewBuilder
    private func pill(for suggestion: AmbientSuggestion) -> some View {
        Button {
            onTap(suggestion)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: suggestion.icon ?? "bubble.left.and.text.bubble.right")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(LitterTheme.textMuted)
                Text(suggestion.title ?? suggestion.prompt ?? suggestion.id)
                    .litterFont(size: 13)
                    .foregroundStyle(LitterTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .modifier(GlassCapsuleModifier(interactive: true))
    }
}
