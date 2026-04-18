import Foundation
import WidgetKit

/// Timeline entry shared by all three complications. Designed to round-trip
/// through the `group.com.sigkitten.litter` App Group — the iOS app writes
/// the current running-task snapshot into `UserDefaults` and complications
/// read it on each reload.
struct LitterComplicationEntry: TimelineEntry {
    enum Mode: String, Codable {
        case idle, running, offline
    }

    let date: Date
    let mode: Mode
    /// Seconds since the task started, for the runtime display.
    let runtimeSeconds: Int
    /// Progress [0, 1] of the running task — used for circular arc + pips.
    let progress: Double
    /// Short human label shown on rectangular / corner faces.
    let title: String
    /// Current tool-call line, shown in the rectangular family only.
    let toolLine: String
    /// Count of connected servers (idle mode only).
    let serverCount: Int

    var runtimeLabel: String {
        let m = runtimeSeconds / 60
        let s = runtimeSeconds % 60
        return String(format: "%d:%02d", m, s)
    }

    static let placeholder = LitterComplicationEntry(
        date: .now,
        mode: .running,
        runtimeSeconds: 42,
        progress: 0.4,
        title: "fix auth token expiry",
        toolLine: "edit_file src/auth.go",
        serverCount: 3
    )

    static let idlePlaceholder = LitterComplicationEntry(
        date: .now,
        mode: .idle,
        runtimeSeconds: 0,
        progress: 1,
        title: "3 servers ready",
        toolLine: "tap to open",
        serverCount: 3
    )
}

/// Reads complication data out of the shared App Group.
enum LitterComplicationStore {
    static let appGroup = "group.com.sigkitten.litter"
    private static let key = "complication.snapshot.v1"

    static func current() -> LitterComplicationEntry {
        guard
            let defaults = UserDefaults(suiteName: appGroup),
            let data = defaults.data(forKey: key),
            let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return .placeholder
        }
        return LitterComplicationEntry(
            date: .now,
            mode: payload.mode,
            runtimeSeconds: payload.runtimeSeconds,
            progress: payload.progress,
            title: payload.title,
            toolLine: payload.toolLine,
            serverCount: payload.serverCount
        )
    }

    /// Write a snapshot from the iOS container app. Called opportunistically
    /// on task start/step change/task end.
    static func write(_ entry: LitterComplicationEntry) {
        guard let defaults = UserDefaults(suiteName: appGroup) else { return }
        let payload = Payload(
            mode: entry.mode,
            runtimeSeconds: entry.runtimeSeconds,
            progress: entry.progress,
            title: entry.title,
            toolLine: entry.toolLine,
            serverCount: entry.serverCount
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        defaults.set(data, forKey: key)
    }

    private struct Payload: Codable {
        let mode: LitterComplicationEntry.Mode
        let runtimeSeconds: Int
        let progress: Double
        let title: String
        let toolLine: String
        let serverCount: Int
    }
}
