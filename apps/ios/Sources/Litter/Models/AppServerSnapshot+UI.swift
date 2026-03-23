import Foundation

extension AppServerSnapshot {
    var isConnected: Bool {
        health == .connected
    }
}
