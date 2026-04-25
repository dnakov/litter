import Foundation
import SwiftUI

enum LitterPlatform {
#if targetEnvironment(macCatalyst)
    static let isCatalyst = true
#else
    static let isCatalyst = false
#endif

    /// `true` only on the unsandboxed Mac Catalyst lane (Developer ID
    /// notarized .dmg). Sandboxed Catalyst (Mac App Store) always sets
    /// `APP_SANDBOX_CONTAINER_ID`, so its absence on a Catalyst process
    /// is a reliable indicator that the App Sandbox is off and we can
    /// spawn child processes (codex app-server, etc.).
    static let isDirectDistMac: Bool = {
        guard isCatalyst else { return false }
        return ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil
    }()

    static let supportsLocalRuntime = !isCatalyst
    static let supportsVoiceRuntime = !isCatalyst

    static func bootstrapLocalRuntimeIfNeeded() {
#if !targetEnvironment(macCatalyst)
        migrateWorkDirIfHostPath()
        codex_ish_init()
        litter_install_ish_hook()
#endif
    }

    /// iSH cannot see iOS sandbox paths. If the persisted `workDir` is one
    /// (carried over from an older build that ran shell commands directly in
    /// the iOS sandbox, or from the @AppStorage default), reset it to a
    /// fakefs-internal path so the model doesn't waste a cd-probe round-trip
    /// on every fresh turn.
    private static func migrateWorkDirIfHostPath() {
        let key = "workDir"
        let stored = UserDefaults.standard.string(forKey: key) ?? ""
        let hostPrefixes = ["/var/", "/private/", "/Users/", "/Library/", "/System/", "/Applications/"]
        let isHostPath = hostPrefixes.contains { stored.hasPrefix($0) }
        if stored.isEmpty || isHostPath {
            UserDefaults.standard.set("/root", forKey: key)
        }
    }

    static func defaultLocalWorkingDirectory() -> String {
#if targetEnvironment(macCatalyst)
        return NSHomeDirectory()
#else
        return codex_ish_default_cwd() as String? ?? NSHomeDirectory()
#endif
    }

    static func isRegularSurface(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isCatalyst || horizontalSizeClass == .regular
    }
}
