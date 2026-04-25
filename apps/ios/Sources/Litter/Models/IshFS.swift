import Foundation

/// Thin Swift wrapper over UniFFI `ishRun` for filesystem operations that
/// the iOS-side `FileManager` can't do — the iSH fakefs is invisible to
/// host iOS APIs, so anything that needs to enumerate or mutate paths
/// inside the kernel's view (e.g. `/root`, `/etc`, `/usr`) has to go
/// through the persistent shell.
///
/// Keep this surface tiny. Most product logic should still happen Rust-side
/// via the exec hook — this is only for UI that has to read fakefs state
/// directly (the directory picker, primarily).
enum IshFS {
    struct Result {
        let exitCode: Int32
        let output: String
    }

    /// POSIX single-quote a string for safe interpolation into a shell
    /// command: `'x'` stays `'x'`, `x's` becomes `'x'\''s'`.
    static func shellQuote(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    /// Run `cmd` through the persistent iSH shell. `ishRun` is thread-safe
    /// but serializes internally, so we hop to a background task to avoid
    /// blocking the caller (typically a SwiftUI MainActor path).
    static func run(_ cmd: String, cwd: String? = nil) async -> Result {
        await Task.detached(priority: .userInitiated) {
            let res = ishRun(cmd: cmd, cwd: cwd ?? "")
            let output = String(data: res.output, encoding: .utf8) ?? ""
            return Result(exitCode: res.exitCode, output: output)
        }.value
    }
}
