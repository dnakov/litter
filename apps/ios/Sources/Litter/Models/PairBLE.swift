import CoreBluetooth
import Foundation

/// Shared constants and helpers for the BLE-based proximity channel that
/// supplements `NearbyInteraction` ranging in the Mac pairing flow. UWB is
/// unavailable on every shipping Mac, so BLE RSSI is the actual proximity
/// signal that gates auto-pair on Catalyst hosts.
enum PairBLE {
    /// 128-bit service UUID advertised by `MacPairingHost` and scanned for
    /// by `NearbyMacPairing`. Treated as the litter-pair beacon namespace —
    /// other apps using a different UUID won't show up in our scan.
    static let serviceUUID = CBUUID(string: "DDC6E1E6-7A7E-4D80-A1D0-B6F1F08C9D10")

    /// RSSI threshold (dBm) considered "close enough to auto-pair." Roughly
    /// 0.5–1m for typical BLE peers; tightening past -50 dBm makes pairing
    /// finicky because RSSI is noisy at short range.
    static let proximityRssiThreshold: Int = -55

    /// Number of consecutive close samples (per peer) required before we
    /// fire pair_request. With duplicate-allowed scanning the iPhone gets
    /// ~2-5 advertisements/sec, so 3 samples ≈ 1s of sustained proximity —
    /// enough to debounce someone walking past.
    static let proximityRequiredHits: Int = 3

    /// Window size for the RSSI sliding mean used in the debug UI. The
    /// auto-trigger uses raw consecutive-samples instead of the mean to
    /// avoid stale-reading false positives.
    static let smoothingWindow: Int = 5

    /// Reference RSSI at 1m for the iBeacon-style log-distance estimate.
    /// Calibration varies per advertiser/receiver pair; -59 dBm is the
    /// standard iBeacon default.
    static let referenceTxPower: Int = -59

    /// Path-loss exponent for the log-distance model. 2.0 = free space,
    /// 2.5–3.5 = typical indoor with walls/people. We pick 2.5 because
    /// pairing usually happens within a single room.
    static let pathLossExponent: Double = 2.5

    /// Convert an RSSI sample into a coarse distance estimate in meters.
    /// Returns nil for invalid inputs (rssi == 0 means "no read"). The
    /// estimate is noisy by ±2-3m and only meant for the debug view.
    static func estimateDistanceMeters(rssi: Int) -> Double? {
        guard rssi != 0 else { return nil }
        return pow(10.0, Double(referenceTxPower - rssi) / (10.0 * pathLossExponent))
    }

    /// Coarse proximity bucket for UI affordances (compass arrow size, etc.).
    enum Bucket: String {
        case unknown
        case far
        case medium
        case near
        case veryClose

        static func from(rssi: Int?) -> Bucket {
            guard let rssi else { return .unknown }
            switch rssi {
            case ..<(-80): return .far
            case (-80)..<(-65): return .medium
            case (-65)..<(-50): return .near
            default: return .veryClose
            }
        }

        var label: String {
            switch self {
            case .unknown: return "—"
            case .far: return "far"
            case .medium: return "medium"
            case .near: return "near"
            case .veryClose: return "very close"
            }
        }
    }
}

/// Thread-safe-by-MainActor sliding-window RSSI tracker for a single peer.
/// Owns the raw sample buffer, exposes a smoothed mean for UI, and tracks
/// consecutive-close-samples count for the auto-trigger gate.
@MainActor
final class PairBLEPeerTracker {
    private(set) var lastRssi: Int?
    private(set) var consecutiveClose: Int = 0
    private var window: [Int] = []

    func record(rssi: Int) {
        lastRssi = rssi
        window.append(rssi)
        if window.count > PairBLE.smoothingWindow {
            window.removeFirst(window.count - PairBLE.smoothingWindow)
        }
        if rssi >= PairBLE.proximityRssiThreshold {
            consecutiveClose += 1
        } else {
            consecutiveClose = 0
        }
    }

    func reset() {
        lastRssi = nil
        consecutiveClose = 0
        window.removeAll()
    }

    var smoothedRssi: Float? {
        guard !window.isEmpty else { return nil }
        let sum = window.reduce(0, +)
        return Float(sum) / Float(window.count)
    }

    var hasTripped: Bool {
        consecutiveClose >= PairBLE.proximityRequiredHits
    }
}
