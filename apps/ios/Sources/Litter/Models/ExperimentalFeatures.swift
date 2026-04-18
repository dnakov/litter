import Foundation
import Observation

enum LitterFeature: String, CaseIterable, Identifiable {
    case realtimeVoice = "realtime_voice"
    case ipc = "ipc"
    case generativeUI = "generative_ui"
    case appleWatch = "apple_watch"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .realtimeVoice: return "Realtime"
        case .ipc: return "IPC"
        case .generativeUI: return "Generative UI"
        case .appleWatch: return "Apple Watch"
        }
    }

    var description: String {
        switch self {
        case .realtimeVoice: return "Show the realtime voice launcher on the home screen."
        case .ipc: return "Attach to desktop IPC over SSH for faster sync, approvals, and resume. Requires reconnecting the server."
        case .generativeUI: return "Show interactive widgets, diagrams, and charts inline in conversations. Requires starting a new thread."
        case .appleWatch: return "Push server, task, and approval state to a paired Apple Watch. Requires the Litter watch app to be installed."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .realtimeVoice: return true
        case .ipc: return false
        case .generativeUI: return false
        case .appleWatch:
            // Enabled in Debug builds so local dev auto-pushes to a paired
            // watch. Disabled in Release so shipping builds don't start
            // WCSession or reach for a watch that isn't in the App Store
            // binary anyway (see project.yml — watch target is not
            // embedded in the iOS app).
            #if DEBUG
            return true
            #else
            return false
            #endif
        }
    }
}

@Observable
final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()

    @ObservationIgnored private let key = "litter.experimentalFeatures"
    private var overrides: [String: Bool]

    private init() {
        overrides = UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    private func persistOverrides() {
        UserDefaults.standard.set(overrides, forKey: key)
    }

    func isEnabled(_ feature: LitterFeature) -> Bool {
        overrides[feature.rawValue] ?? feature.defaultEnabled
    }

    func setEnabled(_ feature: LitterFeature, _ value: Bool) {
        var map = overrides
        if value == feature.defaultEnabled {
            map.removeValue(forKey: feature.rawValue)
        } else {
            map[feature.rawValue] = value
        }
        overrides = map
        persistOverrides()
    }

    func ipcSocketPathOverride() -> String? {
        isEnabled(.ipc) ? nil : ""
    }
}
