import Foundation

/// Single source of truth for the user-facing `~` on the local codex.
/// Resolves to `/root` inside the iSH Alpine fakefs — what
/// `ishDefaultCwd()` returns.
///
/// Used by `PathDisplay` to shorten `/root/foo` to `~/foo` in the UI, and
/// by the local-server directory picker to scope navigation. Never used
/// for remote-server paths.
///
/// Note: the iOS-side `DirectoryPickerView` walks paths via `FileManager`,
/// which cannot see inside the fakefs. Picker UX for local iSH paths is a
/// separate follow-up.
enum HomeAnchor {
    static let path: String = "/root"
}
