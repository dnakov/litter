import Foundation

/// Convert filesystem paths to short, user-facing strings.
///
/// For **local** codex paths, rewrites the app-container Documents home
/// and the app's `NSTemporaryDirectory()` to `~` and `/tmp` so the UI
/// shows `~/projects/foo` and `/tmp/x.txt` instead of
/// `/var/mobile/Containers/Data/Application/<UUID>/Documents/home/codex/...`.
///
/// For **remote** paths, delegates to the existing `abbreviateHomePath`
/// which shortens `/Users/<user>/<subpath>` and `/home/<user>/<subpath>`
/// to `~/<subpath>`.
enum PathDisplay {
    /// Callers pass `isLocal = true` only when `raw` is a path on the
    /// in-process iOS codex. Remote-server paths (SSH/WebSocket) go
    /// through `abbreviateHomePath`.
    static func display(_ raw: String, isLocal: Bool) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return isLocal ? "~" : trimmed }
        guard isLocal else { return abbreviateHomePath(trimmed) }
        let home = HomeAnchor.path
        if trimmed == home { return "~" }
        if trimmed.hasPrefix(home + "/") {
            return "~/" + trimmed.dropFirst(home.count + 1)
        }
        let tmp = realTmp()
        if !tmp.isEmpty {
            if trimmed == tmp { return "/tmp" }
            if trimmed.hasPrefix(tmp + "/") {
                return "/tmp/" + trimmed.dropFirst(tmp.count + 1)
            }
        }
        return trimmed
    }

    /// Inverse of `display` for the local case. Accepts user-entered
    /// display strings (`~/foo`, `/tmp/x`) and produces an absolute path
    /// on the iOS sandbox. No-op for remote paths.
    static func expand(_ display: String, isLocal: Bool) -> String {
        guard isLocal else { return display }
        if display == "~" { return HomeAnchor.path }
        if display.hasPrefix("~/") {
            return HomeAnchor.path + "/" + display.dropFirst(2)
        }
        let tmp = realTmp()
        if !tmp.isEmpty {
            if display == "/tmp" { return tmp }
            if display.hasPrefix("/tmp/") {
                return tmp + "/" + display.dropFirst(5)
            }
        }
        return display
    }

    private static func realTmp() -> String {
        let raw = NSTemporaryDirectory()
        // Strip trailing slash so comparisons are uniform with prefix
        // matching that adds `/`.
        if raw.hasSuffix("/") { return String(raw.dropLast()) }
        return raw
    }
}
