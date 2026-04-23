import Foundation

/// Directory that holds saved-app files (`saved_apps.json`, `html/<id>.html`,
/// `state/<id>.json`) under `Documents/Apps/`. Saved apps are user content,
/// so they live under Documents alongside the codex workspace.
///
/// Rust `saved_apps.rs` writes directly under whatever path it receives
/// (no `apps/` suffix). Pass `SavedAppsDirectory.path` into every
/// `savedApp*(directory:)` call.
enum SavedAppsDirectory {
    static let path: String = {
        let fm = FileManager.default
        let base = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("Apps", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.path
    }()
}
