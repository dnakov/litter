import Foundation

struct SavedServer: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let codexPorts: [UInt16]
    let sshPort: UInt16?
    let source: ServerSource
    let hasCodexServer: Bool
    let wakeMAC: String?
    let preferredConnectionMode: PreferredConnectionMode?
    let preferredCodexPort: UInt16?
    let sshPortForwardingEnabled: Bool?
    let websocketURL: String?
    let rememberedByUser: Bool

    init(
        id: String,
        name: String,
        hostname: String,
        port: UInt16?,
        codexPorts: [UInt16],
        sshPort: UInt16?,
        source: ServerSource,
        hasCodexServer: Bool,
        wakeMAC: String?,
        preferredConnectionMode: PreferredConnectionMode?,
        preferredCodexPort: UInt16?,
        sshPortForwardingEnabled: Bool?,
        websocketURL: String?,
        rememberedByUser: Bool = false
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.codexPorts = codexPorts
        self.sshPort = sshPort
        self.source = source
        self.hasCodexServer = hasCodexServer
        self.wakeMAC = wakeMAC
        self.preferredConnectionMode = preferredConnectionMode
        self.preferredCodexPort = preferredCodexPort
        self.sshPortForwardingEnabled = sshPortForwardingEnabled
        self.websocketURL = websocketURL
        self.rememberedByUser = rememberedByUser
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case hostname
        case port
        case codexPorts
        case sshPort
        case source
        case hasCodexServer
        case wakeMAC
        case preferredConnectionMode
        case preferredCodexPort
        case sshPortForwardingEnabled
        case websocketURL
        case rememberedByUser
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let port = try container.decodeIfPresent(UInt16.self, forKey: .port)
        let hasCodexServer = try container.decode(Bool.self, forKey: .hasCodexServer)

        self.id = try container.decode(String.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.hostname = try container.decode(String.self, forKey: .hostname)
        self.port = port
        self.codexPorts = try container.decodeIfPresent([UInt16].self, forKey: .codexPorts)
            ?? (hasCodexServer ? (port.map { [$0] } ?? []) : [])
        self.sshPort = try container.decodeIfPresent(UInt16.self, forKey: .sshPort)
        self.source = try container.decode(ServerSource.self, forKey: .source)
        self.hasCodexServer = hasCodexServer
        self.wakeMAC = try container.decodeIfPresent(String.self, forKey: .wakeMAC)
        self.preferredConnectionMode = try container.decodeIfPresent(
            PreferredConnectionMode.self,
            forKey: .preferredConnectionMode
        )
        self.preferredCodexPort = try container.decodeIfPresent(UInt16.self, forKey: .preferredCodexPort)
        self.sshPortForwardingEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .sshPortForwardingEnabled
        )
        self.websocketURL = try container.decodeIfPresent(String.self, forKey: .websocketURL)
        self.rememberedByUser = try container.decodeIfPresent(Bool.self, forKey: .rememberedByUser) ?? true
    }

    func toDiscoveredServer() -> DiscoveredServer {
        let codexPort = hasCodexServer ? (preferredCodexPort ?? port) : nil
        let resolvedSshPort = sshPort ?? (hasCodexServer ? nil : port)
        return DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: codexPort,
            codexPorts: resolvedCodexPorts,
            sshPort: resolvedSshPort,
            source: source,
            hasCodexServer: hasCodexServer,
            wakeMAC: wakeMAC,
            sshPortForwardingEnabled: false,
            websocketURL: websocketURL,
            preferredConnectionMode: migratedPreferredConnectionMode,
            preferredCodexPort: preferredCodexPort
        )
    }

    static func from(_ server: DiscoveredServer, rememberedByUser: Bool = false) -> SavedServer {
        SavedServer(
            id: server.id,
            name: server.name,
            hostname: server.hostname,
            port: server.port,
            codexPorts: server.codexPorts,
            sshPort: server.sshPort,
            source: server.source,
            hasCodexServer: server.hasCodexServer,
            wakeMAC: server.wakeMAC,
            preferredConnectionMode: server.preferredConnectionMode,
            preferredCodexPort: server.preferredCodexPort,
            sshPortForwardingEnabled: nil,
            websocketURL: server.websocketURL,
            rememberedByUser: rememberedByUser
        )
    }

    private var resolvedCodexPorts: [UInt16] {
        if !codexPorts.isEmpty {
            return codexPorts
        }
        if let port, hasCodexServer {
            return [port]
        }
        return []
    }

    private var migratedPreferredConnectionMode: PreferredConnectionMode? {
        preferredConnectionMode ?? (sshPortForwardingEnabled == true ? .ssh : nil)
    }

    func toRecord() -> SavedServerRecord {
        SavedServerRecord(
            id: id,
            name: name,
            hostname: hostname,
            port: port ?? 0,
            codexPorts: codexPorts,
            sshPort: sshPort,
            source: source.rawValue,
            hasCodexServer: hasCodexServer,
            wakeMac: wakeMAC,
            preferredConnectionMode: preferredConnectionMode?.rawValue,
            preferredCodexPort: preferredCodexPort,
            sshPortForwardingEnabled: sshPortForwardingEnabled,
            websocketUrl: websocketURL,
            rememberedByUser: rememberedByUser
        )
    }
}
