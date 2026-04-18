import SwiftUI

/// Shared colors for the complication bundle. Kept separate from
/// `WatchTheme` so the complication target doesn't need the full watch-app
/// source tree.
enum LitterComplicationTint {
    static let ginger = Color(.sRGB, red: 245/255, green: 158/255, blue: 11/255, opacity: 1)
    static let gingerLight = Color(.sRGB, red: 252/255, green: 212/255, blue: 114/255, opacity: 1)
}
