import Foundation
import SwiftUI

enum LitterPlatform {
#if targetEnvironment(macCatalyst)
    static let isCatalyst = true
#else
    static let isCatalyst = false
#endif

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
