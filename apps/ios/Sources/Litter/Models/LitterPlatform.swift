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
        codex_ios_system_init()
#endif
    }

    static func defaultLocalWorkingDirectory() -> String {
#if targetEnvironment(macCatalyst)
        return NSHomeDirectory()
#else
        return codex_ios_default_cwd() as String? ?? NSHomeDirectory()
#endif
    }

    static func isRegularSurface(horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        isCatalyst || horizontalSizeClass == .regular
    }
}
