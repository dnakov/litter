import SwiftUI

/// Shared visual language for "this thing's current state" — used for task
/// rows (active / hydrating / hydrated / idle) and server pills (connected /
/// connecting / failed / idle). Colors are fixed green/orange/red so the
/// meaning reads the same across themes.
enum StatusDotState {
    /// Solid green. Something is done / healthy.
    case ok
    /// Pulsing green. Something is live and running right now.
    case active
    /// Pulsing orange. Work in flight (connecting, reconnecting, loading).
    case pending
    /// Solid red. Failed state that needs attention.
    case error
    /// Empty grey ring. Known-but-dormant state (disconnected, not-loaded).
    case idle
}

struct StatusDot: View {
    let state: StatusDotState
    var size: CGFloat = 10

    var body: some View {
        Group {
            switch state {
            case .ok:
                Circle().fill(Color.green).frame(width: size, height: size)
            case .active:
                pulsingDot(color: .green)
            case .pending:
                pulsingDot(color: .orange)
            case .error:
                Circle().fill(Color.red).frame(width: size, height: size)
            case .idle:
                Circle()
                    .stroke(LitterTheme.textMuted.opacity(0.6), lineWidth: 1.5)
                    .frame(width: size + 2, height: size + 2)
            }
        }
        .frame(width: size + 2, height: size + 2)
    }

    /// TimelineView-driven pulse. Unlike a `@State` + `.onAppear` +
    /// `.repeatForever` setup (which can silently stop after List row
    /// recycling), this ties the animation directly to the scene clock —
    /// every frame SwiftUI re-evaluates with the current time and the
    /// derived opacity/scale, so the pulse is always running as long as
    /// the dot is visible.
    private func pulsingDot(color: Color) -> some View {
        TimelineView(.animation) { context in
            // Period ≈ 1.6s; opacity sweeps 0.35 → 1.0, scale 0.85 → 1.0.
            let t = context.date.timeIntervalSinceReferenceDate
            let phase = (sin(t * .pi / 0.8) + 1) / 2  // 0 → 1
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .opacity(0.35 + phase * 0.65)
                .scaleEffect(0.85 + phase * 0.15)
        }
    }
}
