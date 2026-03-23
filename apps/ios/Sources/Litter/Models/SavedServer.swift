import Foundation

struct SavedServer: Codable, Identifiable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let sshPort: UInt16?
    let source: ServerSource
    let hasCodexServer: Bool
    let wakeMAC: String?
    let sshPortForwardingEnabled: Bool?
    let websocketURL: String?

    func toDiscoveredServer() -> DiscoveredServer {
        let codexPort = hasCodexServer ? port : nil
        let resolvedSshPort = sshPort ?? (hasCodexServer ? nil : port)
        return DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: codexPort,
            sshPort: resolvedSshPort,
            source: source,
            hasCodexServer: hasCodexServer,
            wakeMAC: wakeMAC,
            sshPortForwardingEnabled: sshPortForwardingEnabled ?? false,
            websocketURL: websocketURL
        )
    }

    static func from(_ server: DiscoveredServer) -> SavedServer {
        SavedServer(
            id: server.id,
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            sshPort: server.sshPort,
            source: server.source,
            hasCodexServer: server.hasCodexServer,
            wakeMAC: server.wakeMAC,
            sshPortForwardingEnabled: server.sshPortForwardingEnabled,
            websocketURL: server.websocketURL
        )
    }
}
