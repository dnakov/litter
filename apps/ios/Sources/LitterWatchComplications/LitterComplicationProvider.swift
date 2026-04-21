import Foundation
import WidgetKit

/// Single `TimelineProvider` shared by all three complications. The provider
/// emits one entry representing "right now", plus a cadence of future entries
/// for the runtime clock to keep ticking for the next 30 minutes.
struct LitterComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> LitterComplicationEntry {
        .placeholder
    }

    func getSnapshot(in context: Context, completion: @escaping (LitterComplicationEntry) -> Void) {
        completion(LitterComplicationStore.current())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LitterComplicationEntry>) -> Void) {
        let base = LitterComplicationStore.current()
        let now = Date()
        var entries: [LitterComplicationEntry] = []

        if base.mode == .running {
            // Tick once a minute for the next 30m so the runtime label updates.
            for step in 0..<30 {
                entries.append(
                    LitterComplicationEntry(
                        date: now.addingTimeInterval(TimeInterval(step) * 60),
                        mode: .running,
                        runtimeSeconds: base.runtimeSeconds + step * 60,
                        progress: min(1, base.progress + Double(step) * 0.01),
                        title: base.title,
                        toolLine: base.toolLine,
                        serverCount: base.serverCount
                    )
                )
            }
        } else {
            entries.append(base)
        }

        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(60 * 15))))
    }
}
