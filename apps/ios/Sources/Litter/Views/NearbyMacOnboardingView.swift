#if !targetEnvironment(macCatalyst)
import SwiftUI

/// Full-screen first-launch prompt: "Move your iPhone close to your Mac
/// to set up Litter." Surfaces current NI distance when available and
/// transitions through the pair state machine states (`searching` →
/// `connected` → `awaiting_confirm` → `paired` / `rejected`).
struct NearbyMacOnboardingView: View {
    let state: NearbyMacPairingState
    let macName: String?
    let distance: Float?
    let onCancel: () -> Void
    let onRetry: () -> Void

    private var headline: String {
        switch state {
        case .searching:
            return "Looking for your Mac"
        case .connecting:
            return "Connecting"
        case .handshaking:
            return "Move your iPhone close to your Mac"
        case .awaitingConfirm:
            return "Waiting for your Mac to accept…"
        case .paired:
            return "Paired"
        case .rejected:
            return "Pairing declined"
        case .failed:
            return "Pairing failed"
        }
    }

    private var subline: String {
        switch state {
        case .searching:
            return "Make sure Litter is open on your Mac and both are on the same Wi-Fi."
        case .connecting:
            return macName.map { "Connecting to \($0)…" } ?? "Opening a pair channel…"
        case .handshaking:
            if let distance {
                return String(format: "About %.1f m away. Bring it closer.", distance)
            }
            return macName.map { "Move your iPhone close to \($0)." } ?? "Bring your iPhone close to your Mac."
        case .awaitingConfirm:
            return "Check your Mac to accept the pair request."
        case .paired:
            return "Setup complete. Opening Litter…"
        case .rejected:
            return "You can try again or set up a server manually."
        case .failed:
            return "Couldn't pair. Make sure both devices are on the same Wi-Fi and try again."
        }
    }

    private var statusSymbol: String {
        switch state {
        case .searching, .connecting, .handshaking, .awaitingConfirm:
            return "antenna.radiowaves.left.and.right"
        case .paired:
            return "checkmark.circle.fill"
        case .rejected:
            return "xmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    var body: some View {
        ZStack {
            LitterTheme.backgroundGradient.ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: statusSymbol)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .foregroundColor(iconColor)
                    .symbolEffect(.pulse, options: .repeating, isActive: animating)
                Text(headline)
                    .litterFont(.headline)
                    .foregroundColor(LitterTheme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(subline)
                    .litterFont(.body)
                    .foregroundColor(LitterTheme.textMuted)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                if case .handshaking = state, let distance {
                    distanceBar(meters: distance)
                        .padding(.horizontal, 48)
                }
                Spacer()
                actionButtons
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var iconColor: Color {
        switch state {
        case .paired:
            return LitterTheme.accent
        case .rejected, .failed:
            return .red
        default:
            return LitterTheme.accent
        }
    }

    private var animating: Bool {
        switch state {
        case .searching, .connecting, .handshaking, .awaitingConfirm:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch state {
        case .searching, .connecting, .handshaking, .awaitingConfirm:
            Button {
                onCancel()
            } label: {
                Text("Skip, set up manually")
                    .litterFont(.body)
                    .foregroundColor(LitterTheme.textMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
        case .rejected, .failed:
            VStack(spacing: 12) {
                Button {
                    onRetry()
                } label: {
                    Text("Try Again")
                        .litterFont(.body)
                        .foregroundColor(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(LitterTheme.accent)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Button {
                    onCancel()
                } label: {
                    Text("Set up manually")
                        .litterFont(.body)
                        .foregroundColor(LitterTheme.textMuted)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
        case .paired:
            EmptyView()
        }
    }

    private func distanceBar(meters: Float) -> some View {
        // Visual proximity bar: fills as distance approaches 1m.
        let clamped = min(max(meters, 0.1), 4.0)
        // Empty at >=4m, full at <=0.5m.
        let fill = max(0.0, min(1.0, (4.0 - clamped) / 3.5))
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LitterTheme.surface)
                    .frame(height: 6)
                Capsule()
                    .fill(LitterTheme.accent)
                    .frame(width: geo.size.width * CGFloat(fill), height: 6)
            }
        }
        .frame(height: 6)
    }
}

/// High-level state for the onboarding UI. Derived from the underlying
/// Rust `PairEvent` stream by `NearbyMacPairing`.
enum NearbyMacPairingState: Equatable {
    case searching
    case connecting
    case handshaking
    case awaitingConfirm
    case paired
    case rejected
    case failed
}
#endif
