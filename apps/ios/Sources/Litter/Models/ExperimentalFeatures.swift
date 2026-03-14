import Foundation

enum LitterFeature: String, CaseIterable, Identifiable {
    case generativeUI = "generative_ui"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .generativeUI: return "Generative UI"
        }
    }

    var description: String {
        switch self {
        case .generativeUI: return "Show interactive widgets, diagrams, and charts inline in conversations. Requires starting a new thread."
        }
    }

    var defaultEnabled: Bool {
        switch self {
        case .generativeUI: return false
        }
    }
}

final class ExperimentalFeatures {
    static let shared = ExperimentalFeatures()

    private let key = "litter.experimentalFeatures"

    private var overrides: [String: Bool] {
        get { UserDefaults.standard.dictionary(forKey: key) as? [String: Bool] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: key) }
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
    }
}
