import Foundation

/// Directory that holds the shared Rust preferences file. Today this points
/// at Application Support; future cloud sync can route this to an iCloud
/// ubiquity container without the rest of the app caring.
enum MobilePreferencesDirectory {
    static let path: String = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("LitterPreferences", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }()
}
