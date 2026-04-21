import Foundation

/// Last-used server / project selection for the home screen. Backed by the
/// shared Rust preferences store so this state can sync alongside pinned
/// threads once a cloud sync backend lands.
@MainActor
enum SavedProjectStore {
    static var selectedServerId: String? {
        get { loadSelection().selectedServerId }
        set {
            var selection = loadSelection()
            selection.selectedServerId = newValue
            writeSelection(selection)
        }
    }

    static var selectedProjectId: String? {
        get { loadSelection().selectedProjectId }
        set {
            var selection = loadSelection()
            selection.selectedProjectId = newValue
            writeSelection(selection)
        }
    }

    private static func loadSelection() -> HomeSelection {
        preferencesLoad(directory: MobilePreferencesDirectory.path).homeSelection
    }

    private static func writeSelection(_ selection: HomeSelection) {
        _ = preferencesSetHomeSelection(
            directory: MobilePreferencesDirectory.path,
            selection: selection
        )
    }
}
