import SwiftUI
import WidgetKit

/// Bundle of watchOS complications.
///
/// - `accessoryCircular` — running-task timer / idle-server count
/// - `accessoryCorner`   — bottom-right corner showing runtime + task title
/// - `accessoryRectangular` — modular hero slot with full task line
///
/// All three share a single timeline provider that reflects the latest
/// snapshot published to the App Group by the iOS container app.
@main
struct LitterWatchComplicationsBundle: WidgetBundle {
    var body: some Widget {
        LitterCircularComplication()
        LitterCornerComplication()
        LitterRectangularComplication()
    }
}
