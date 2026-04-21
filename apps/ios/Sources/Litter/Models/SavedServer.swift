import Foundation

enum SavedServerBackendKind: String, Codable, Equatable {
    case codex
    case openCode
}

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
    let backendKind: SavedServerBackendKind
    let openCodeBaseURL: String?
    let openCodeBasicAuthUsername: String?
    let openCodeBasicAuthPassword: String?
    let openCodeKnownDirectories: [String]

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
        rememberedByUser: Bool = false,
        backendKind: SavedServerBackendKind = .codex,
        openCodeBaseURL: String? = nil,
        openCodeBasicAuthUsername: String? = nil,
        openCodeBasicAuthPassword: String? = nil,
        openCodeKnownDirectories: [String] = []
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
        self.backendKind = backendKind
        self.openCodeBaseURL = openCodeBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openCodeBasicAuthUsername = openCodeBasicAuthUsername?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openCodeBasicAuthPassword = openCodeBasicAuthPassword
        self.openCodeKnownDirectories = Self.normalizedOpenCodeDirectories(openCodeKnownDirectories)
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
        case backendKind
        case openCodeBaseURL
        case openCodeBasicAuthUsername
        case openCodeBasicAuthPassword
        case openCodeKnownDirectories
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
        self.backendKind = try container.decodeIfPresent(SavedServerBackendKind.self, forKey: .backendKind) ?? .codex
        self.openCodeBaseURL = (
            try container.decodeIfPresent(String.self, forKey: .openCodeBaseURL)
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openCodeBasicAuthUsername = (
            try container.decodeIfPresent(
                String.self,
                forKey: .openCodeBasicAuthUsername
            )
        )?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openCodeBasicAuthPassword = try container.decodeIfPresent(
            String.self,
            forKey: .openCodeBasicAuthPassword
        )
        self.openCodeKnownDirectories = Self.normalizedOpenCodeDirectories(
            try container.decodeIfPresent([String].self, forKey: .openCodeKnownDirectories) ?? []
        )
    }

    var deduplicationKey: String {
        switch backendKind {
        case .codex:
            if let websocketURL, let url = URL(string: websocketURL) {
                let host = Self.normalizedKey(url.host ?? hostname)
                return host.isEmpty ? id : "codex:\(host)"
            }
            let host = Self.normalizedKey(hostname)
            return host.isEmpty ? id : "codex:\(host)"
        case .openCode:
            let keySource = openCodeBaseURL ?? hostname
            let key = Self.normalizedKey(keySource)
            return key.isEmpty ? "opencode:\(id)" : "opencode:\(key)"
        }
    }

    func toDiscoveredServer() -> DiscoveredServer? {
        if backendKind == .openCode {
            return DiscoveredServer(
                id: id,
                name: name,
                hostname: hostname,
                port: port,
                backendKind: .openCode,
                source: source,
                hasCodexServer: false,
                wakeMAC: wakeMAC,
                openCodeBaseURL: openCodeBaseURL,
                openCodeRequiresAuth: openCodeBasicAuthUsername != nil || openCodeBasicAuthPassword != nil,
                openCodeKnownDirectories: openCodeKnownDirectories
            )
        }

        let codexPort = hasCodexServer ? (preferredCodexPort ?? port) : nil
        let resolvedSshPort = sshPort ?? (hasCodexServer ? nil : port)
        return DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: codexPort,
            backendKind: .codex,
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

    func normalizedForPersistence() -> SavedServer {
        SavedServer(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            codexPorts: backendKind == .codex ? resolvedCodexPorts : [],
            sshPort: sshPort,
            source: source,
            hasCodexServer: backendKind == .codex ? hasCodexServer : false,
            wakeMAC: wakeMAC,
            preferredConnectionMode: backendKind == .codex ? migratedPreferredConnectionMode : nil,
            preferredCodexPort: backendKind == .codex ? preferredCodexPort : nil,
            sshPortForwardingEnabled: backendKind == .codex ? sshPortForwardingEnabled : nil,
            websocketURL: backendKind == .codex ? websocketURL : nil,
            rememberedByUser: rememberedByUser,
            backendKind: backendKind,
            openCodeBaseURL: openCodeBaseURL,
            openCodeBasicAuthUsername: openCodeBasicAuthUsername,
            openCodeBasicAuthPassword: openCodeBasicAuthPassword,
            openCodeKnownDirectories: openCodeKnownDirectories
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
            rememberedByUser: rememberedByUser,
            backendKind: server.backendKind,
            openCodeBaseURL: server.openCodeBaseURL,
            openCodeKnownDirectories: server.openCodeKnownDirectories
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
            rememberedByUser: rememberedByUser,
            backendKind: backendKind == .openCode ? .openCode : .codex,
            opencodeBaseUrl: openCodeBaseURL,
            opencodeBasicAuthUsername: openCodeBasicAuthUsername,
            opencodeBasicAuthPassword: openCodeBasicAuthPassword,
            opencodeKnownDirectories: openCodeKnownDirectories.map { directory in
                SavedOpenCodeDirectoryScopeRecord(directory: directory)
            }
        )
    }

    private static func normalizedOpenCodeDirectories(_ directories: [String]) -> [String] {
        var seen = Set<String>()
        return directories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { seen.insert($0).inserted }
    }

    private static func normalizedKey(_ raw: String) -> String {
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            let host = (url.host ?? raw).lowercased()
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }

        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")

        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        return normalized.lowercased()
    }
}
