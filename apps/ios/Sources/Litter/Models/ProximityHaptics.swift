#if !targetEnvironment(macCatalyst)
import Foundation
import UIKit

/// Drives haptic feedback for the Pair flow's proximity view. Tick rate +
/// intensity scale with a 0–1 proximity score; threshold crossings get a
/// notification haptic, and `success()` plays the celebratory pattern when
/// pair_accept arrives.
///
/// Lives on the iPhone only — Catalyst doesn't have the haptic feedback
/// generators (and Macs don't have Taptic Engines anyway).
@MainActor
final class ProximityHaptics {
    private let lightFB = UIImpactFeedbackGenerator(style: .light)
    private let mediumFB = UIImpactFeedbackGenerator(style: .medium)
    private let heavyFB = UIImpactFeedbackGenerator(style: .heavy)
    private let notificationFB = UINotificationFeedbackGenerator()

    private var tickTask: Task<Void, Never>?
    private var lastBucket: PairBLE.Bucket = .unknown

    func prepare() {
        lightFB.prepare()
        mediumFB.prepare()
        heavyFB.prepare()
        notificationFB.prepare()
    }

    /// Update the haptic engine with the current proximity score (0 = far,
    /// 1 = close enough to pair) and an "approach speed" magnitude that
    /// adds extra emphasis when actively moving toward the peer. Called
    /// from the view's `.onChange` handlers as the underlying observables
    /// update.
    func update(proximity: Float, approaching: Bool) {
        guard proximity > 0.05 else {
            stopTicker()
            return
        }
        // Tick interval shrinks from ~700 ms (far edge) to ~70 ms (very
        // close). Extra bump if iPhone is actively approaching — gives
        // the "you're getting warmer" feeling.
        let baseInterval = max(0.07, 0.7 - Double(proximity) * 0.6)
        let interval = approaching ? baseInterval * 0.7 : baseInterval
        startTicker(interval: interval, proximity: proximity)
    }

    /// Cross-bucket impact (e.g., far → medium → near) — punchier than the
    /// continuous tick, plays once per transition.
    func bucketChanged(to bucket: PairBLE.Bucket) {
        guard bucket != lastBucket else { return }
        lastBucket = bucket
        switch bucket {
        case .veryClose: heavyFB.impactOccurred(intensity: 1.0)
        case .near: mediumFB.impactOccurred(intensity: 0.9)
        case .medium: lightFB.impactOccurred(intensity: 0.8)
        case .far, .unknown: break
        }
    }

    func success() {
        stopTicker()
        notificationFB.notificationOccurred(.success)
    }

    func failure() {
        stopTicker()
        notificationFB.notificationOccurred(.warning)
    }

    func stop() {
        stopTicker()
        lastBucket = .unknown
    }

    // MARK: - Internals

    private func startTicker(interval: Double, proximity: Float) {
        tickTask?.cancel()
        let intensity = max(0.4, min(1.0, CGFloat(proximity)))
        tickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.lightFB.impactOccurred(intensity: intensity)
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    private func stopTicker() {
        tickTask?.cancel()
        tickTask = nil
    }
}
#endif
