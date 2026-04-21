import SwiftUI

/// Swipe-left-to-hide row wrapper. Shows a full-width red "hide" background
/// whose opacity scales with drag distance. If the user drags past the
/// commit threshold and releases, `onHide` is invoked and the caller is
/// expected to remove the row from its list (exit animation is the caller's
/// concern).
struct SwipeableRow<Content: View>: View {
    let onHide: () -> Void
    /// Set to true by the parent while a multi-touch gesture (e.g. the
    /// pinch-to-zoom on the home list) is in flight. The row will not arm,
    /// and any in-progress swipe will spring back.
    var suspended: Bool = false
    @ViewBuilder var content: () -> Content

    @State private var offsetX: CGFloat = 0
    @State private var isCommitting = false
    /// Only start translating the row after we've confirmed the user is
    /// doing a horizontal drag (not a pinch-zoom or vertical scroll).
    @State private var isActivated = false

    private let commitDistance: CGFloat = 90
    private let maxReveal: CGFloat = 140
    /// How far the finger must move before we consider the gesture "started"
    /// as a horizontal swipe. Small enough that the red fill starts showing
    /// almost immediately, but big enough to stay out of tap / pinch / scroll
    /// territory.
    private let activationDistance: CGFloat = 8

    var body: some View {
        ZStack(alignment: .trailing) {
            // Full-row red background, opacity driven by how far we've slid.
            Rectangle()
                .fill(Color.red)
                .opacity(revealOpacity)
                .overlay(alignment: .trailing) {
                    HStack(spacing: 6) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 15, weight: .semibold))
                        Text("hide")
                            .litterMonoFont(size: 13, weight: .semibold)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.trailing, 20)
                    .opacity(revealOpacity)
                }

            content()
                .offset(x: offsetX)
                // `.simultaneousGesture` (not `.gesture`) so the parent
                // ScrollView's vertical pan keeps working. We only move the
                // row once we confirm the drag is a left-leaning horizontal
                // swipe; vertical drags simply scroll the list.
                .simultaneousGesture(
                    DragGesture(minimumDistance: activationDistance, coordinateSpace: .local)
                        .onChanged { g in
                            guard !isCommitting else { return }

                            if suspended {
                                if isActivated || offsetX != 0 {
                                    isActivated = false
                                    springBack()
                                }
                                return
                            }

                            let dx = g.translation.width
                            let dy = g.translation.height

                            if !isActivated {
                                let horizontallyDominant = abs(dx) > abs(dy) * 1.5
                                let leftwardEnough = dx < -activationDistance
                                if horizontallyDominant && leftwardEnough {
                                    isActivated = true
                                } else {
                                    return
                                }
                            }

                            offsetX = max(dx, -maxReveal)
                        }
                        .onEnded { g in
                            guard isActivated, !suspended else {
                                isActivated = false
                                if offsetX != 0 { springBack() }
                                return
                            }
                            isActivated = false
                            let dx = g.translation.width
                            let predicted = g.predictedEndTranslation.width
                            if dx < -commitDistance || predicted < -(commitDistance + 40) {
                                commitHide()
                            } else {
                                springBack()
                            }
                        }
                )
                .onChange(of: suspended) { _, nowSuspended in
                    if nowSuspended && (isActivated || offsetX != 0) {
                        isActivated = false
                        springBack()
                    }
                }
        }
        .clipped()
    }

    private var revealOpacity: Double {
        let progress = min(1.0, max(0.0, Double(-offsetX / commitDistance)))
        return progress
    }

    private func commitHide() {
        isCommitting = true
        withAnimation(.easeOut(duration: 0.22)) {
            offsetX = -1000
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            onHide()
        }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
            offsetX = 0
        }
    }
}
