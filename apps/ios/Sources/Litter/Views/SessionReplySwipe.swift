import SwiftUI

/// Wraps a session row with a right-swipe "reply" gesture. Only commits
/// when the user drags right past a threshold and releases — behaves like
/// iMessage / Telegram quick-reply swipes. Reveal is only left-visible
/// when horizontal motion dominates, so vertical scrolls pass through to
/// the parent `ScrollView`.
struct SessionReplySwipeWrapper<Content: View>: View {
    let onReply: () -> Void
    @ViewBuilder var content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var isActivated = false
    @State private var isCommitting = false

    private let activationDistance: CGFloat = 12
    private let commitDistance: CGFloat = 80
    private let maxReveal: CGFloat = 110

    var body: some View {
        ZStack(alignment: .leading) {
            // Blue reply hint behind the row, revealed as you swipe right.
            HStack(spacing: 6) {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("reply")
                    .litterMonoFont(size: 12, weight: .semibold)
            }
            .foregroundStyle(LitterTheme.accent)
            .padding(.leading, 16)
            .opacity(revealOpacity)

            content()
                .offset(x: offsetX)
                .simultaneousGesture(
                    DragGesture(minimumDistance: activationDistance, coordinateSpace: .local)
                        .onChanged { g in
                            guard !isCommitting else { return }
                            let dx = g.translation.width
                            let dy = g.translation.height

                            if !isActivated {
                                let horizontallyDominant = abs(dx) > abs(dy) * 1.5
                                let rightwardEnough = dx > activationDistance
                                guard horizontallyDominant && rightwardEnough else { return }
                                isActivated = true
                            }

                            offsetX = min(dx, maxReveal)
                        }
                        .onEnded { g in
                            guard isActivated else {
                                isActivated = false
                                return
                            }
                            isActivated = false
                            let dx = g.translation.width
                            let predicted = g.predictedEndTranslation.width
                            if dx > commitDistance || predicted > commitDistance + 40 {
                                commit()
                            } else {
                                springBack()
                            }
                        }
                )
        }
        .clipped()
    }

    private var revealOpacity: Double {
        min(1.0, max(0.0, Double(offsetX / commitDistance)))
    }

    private func commit() {
        isCommitting = true
        // Fire the reply immediately; spring the row back so it's ready
        // to receive the sheet focus.
        onReply()
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            offsetX = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            isCommitting = false
        }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            offsetX = 0
        }
    }
}
