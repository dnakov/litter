import Foundation

enum SessionLaunchSupport {
    struct DirectoryPickerSheetModel: Identifiable, Equatable {
        let id = UUID()
        var selectedServerId: String
    }

    struct ServerPickerSheetModel: Identifiable, Equatable {
        let id = UUID()
        var selectedServerId: String
    }

    static func defaultConnectedServerId(
        connectedServerIds: [String],
        activeThreadKey: ThreadKey?,
        preferredServerId: String? = nil
    ) -> String? {
        guard !connectedServerIds.isEmpty else { return nil }
        if let preferredServerId, connectedServerIds.contains(preferredServerId) {
            return preferredServerId
        }
        if let activeServerId = activeThreadKey?.serverId, connectedServerIds.contains(activeServerId) {
            return activeServerId
        }
        return connectedServerIds.first
    }
}
