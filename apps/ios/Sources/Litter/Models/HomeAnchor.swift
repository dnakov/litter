import Foundation

/// Single source of truth for the user-facing `~` on the local codex.
/// Resolves to the ios-system fake rootfs `home/codex` dir under
/// `Documents/` — i.e. what `codex_ios_default_cwd()` returns.
///
/// Used by `PathDisplay` to shorten `Documents/home/codex/foo` to
/// `~/foo` in the UI, and by the local-server directory picker to scope
/// navigation. Never used for remote-server paths.
enum HomeAnchor {
    static let path: String = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return docs.appendingPathComponent("home/codex", isDirectory: true).path
    }()
}
