import Foundation

extension AppServerSnapshot {
    var isConnected: Bool {
        health == .connected
    }

    var isIpcConnected: Bool {
        hasIpc && !isLocal && isConnected
    }

    var connectionModeLabel: String {
        guard !isLocal else { return "local" }
        return isIpcConnected ? "remote · ipc" : "remote"
    }
}
