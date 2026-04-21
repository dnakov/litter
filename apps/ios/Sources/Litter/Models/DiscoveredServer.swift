import Foundation

enum ServerSource: String, Codable, Hashable {
    case local
    case bonjour
    case ssh
    case tailscale
    case manual

    init(_ source: AppDiscoverySource) {
        switch source {
        case .bonjour, .lanProbe, .arpScan:
            self = .bonjour
        case .tailscale:
            self = .tailscale
        case .manual:
            self = .manual
        case .local:
            self = .local
        }
    }
}

enum PreferredConnectionMode: String, Codable, Hashable {
    case directCodex
    case ssh
}

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let backendKind: SavedServerBackendKind
    let codexPorts: [UInt16]
    let sshPort: UInt16?
    let source: ServerSource
    let hasCodexServer: Bool
    let wakeMAC: String?
    let sshPortForwardingEnabled: Bool
    let websocketURL: String?
    let preferredConnectionMode: PreferredConnectionMode?
    let preferredCodexPort: UInt16?
    let os: String?
    let sshBanner: String?
    let openCodeBaseURL: String?
    let openCodeRequiresAuth: Bool
    let openCodeKnownDirectories: [String]

    init(
        id: String,
        name: String,
        hostname: String,
        port: UInt16?,
        backendKind: SavedServerBackendKind = .codex,
        codexPorts: [UInt16] = [],
        sshPort: UInt16? = nil,
        source: ServerSource,
        hasCodexServer: Bool,
        wakeMAC: String? = nil,
        sshPortForwardingEnabled: Bool = false,
        websocketURL: String? = nil,
        preferredConnectionMode: PreferredConnectionMode? = nil,
        preferredCodexPort: UInt16? = nil,
        os: String? = nil,
        sshBanner: String? = nil,
        openCodeBaseURL: String? = nil,
        openCodeRequiresAuth: Bool = false,
        openCodeKnownDirectories: [String] = []
    ) {
        let normalizedCodexPorts = backendKind == .codex
            ? Self.normalizedPorts(codexPorts, fallback: port)
            : []
        let resolvedPreferredMode = Self.resolvedPreferredConnectionMode(
            preferredConnectionMode,
            codexPorts: normalizedCodexPorts,
            sshPort: backendKind == .codex ? sshPort : nil,
            websocketURL: websocketURL
        )
        let resolvedPreferredCodexPort = Self.resolvedPreferredCodexPort(
            preferredConnectionMode: resolvedPreferredMode,
            preferredCodexPort: preferredCodexPort,
            codexPorts: normalizedCodexPorts
        )

        let resolvedPort: UInt16?
        if backendKind == .openCode {
            resolvedPort = port
        } else {
            resolvedPort = resolvedPreferredCodexPort
                ?? (normalizedCodexPorts.contains(port ?? 0) ? port : nil)
                ?? normalizedCodexPorts.first
        }

        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = resolvedPort
        self.backendKind = backendKind
        self.codexPorts = normalizedCodexPorts
        self.sshPort = backendKind == .codex ? sshPort : nil
        self.source = source
        self.hasCodexServer = backendKind == .codex &&
            (hasCodexServer || !normalizedCodexPorts.isEmpty || websocketURL != nil)
        self.wakeMAC = Self.normalizeWakeMAC(wakeMAC)
        self.sshPortForwardingEnabled = sshPortForwardingEnabled
        self.websocketURL = backendKind == .codex ? websocketURL : nil
        self.preferredConnectionMode = resolvedPreferredMode
        self.preferredCodexPort = resolvedPreferredCodexPort
        self.os = os
        self.sshBanner = sshBanner
        self.openCodeBaseURL = openCodeBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.openCodeRequiresAuth = openCodeRequiresAuth
        self.openCodeKnownDirectories = openCodeKnownDirectories
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var connectionTarget: ConnectionTarget? {
        if backendKind == .openCode { return nil }
        if source == .local { return .local }
        if let websocketURL, let url = URL(string: websocketURL) { return .remoteURL(url) }
        if preferredConnectionMode == .ssh {
            return nil
        }
        if let port = resolvedDirectCodexPort, !requiresConnectionChoice {
            return .remote(host: hostname, port: port)
        }
        return nil
    }

    var resolvedSSHPort: UInt16 {
        sshPort ?? 22
    }

    var availableDirectCodexPorts: [UInt16] {
        codexPorts
    }

    var resolvedDirectCodexPort: UInt16? {
        if preferredConnectionMode == .directCodex, let preferredCodexPort {
            return preferredCodexPort
        }
        if let port, availableDirectCodexPorts.contains(port) {
            return port
        }
        return availableDirectCodexPorts.first
    }

    var canConnectViaSSH: Bool {
        backendKind == .codex && sshPort != nil
    }

    var hasValidPreferredConnection: Bool {
        preferredConnectionMode != nil
    }

    var requiresConnectionChoice: Bool {
        guard backendKind == .codex else { return false }
        guard source != .local, websocketURL == nil else { return false }
        guard preferredConnectionMode == nil else { return false }
        let directCount = availableDirectCodexPorts.count
        return directCount > 1 || (directCount > 0 && canConnectViaSSH)
    }

    func withConnectionPreference(
        _ mode: PreferredConnectionMode?,
        codexPort: UInt16? = nil
    ) -> DiscoveredServer {
        DiscoveredServer(
            id: id,
            name: name,
            hostname: hostname,
            port: codexPort ?? port,
            backendKind: backendKind,
            codexPorts: codexPorts,
            sshPort: sshPort,
            source: source,
            hasCodexServer: hasCodexServer,
            wakeMAC: wakeMAC,
            sshPortForwardingEnabled: sshPortForwardingEnabled,
            websocketURL: websocketURL,
            preferredConnectionMode: mode,
            preferredCodexPort: mode == .directCodex ? (codexPort ?? resolvedDirectCodexPort) : nil,
            os: os,
            sshBanner: sshBanner,
            openCodeBaseURL: openCodeBaseURL,
            openCodeRequiresAuth: openCodeRequiresAuth,
            openCodeKnownDirectories: openCodeKnownDirectories
        )
    }

    var deduplicationKey: String {
        if backendKind == .openCode {
            let key = Self.normalizedOpenCodeKey(openCodeBaseURL ?? hostname)
            return key.isEmpty ? "opencode:\(id)" : "opencode:\(key)"
        }
        if source == .local {
            return "local"
        }

        if let websocketURL, let url = URL(string: websocketURL) {
            let host = Self.normalizedHostKey(url.host ?? hostname)
            return host.isEmpty ? id : "codex:\(host)"
        }

        let host = Self.normalizedHostKey(hostname)
        return host.isEmpty ? id : "codex:\(host)"
    }

    static func normalizeWakeMAC(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let compact = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard compact.count == 12 else { return nil }
        guard compact.allSatisfy({ $0.isHexDigit }) else { return nil }
        var groups: [String] = []
        groups.reserveCapacity(6)
        var index = compact.startIndex
        for _ in 0..<6 {
            let next = compact.index(index, offsetBy: 2)
            groups.append(String(compact[index..<next]))
            index = next
        }
        return groups.joined(separator: ":")
    }

    private static func normalizedPorts(_ ports: [UInt16], fallback: UInt16?) -> [UInt16] {
        var ordered = [UInt16]()
        if let fallback {
            ordered.append(fallback)
        }
        ordered.append(contentsOf: ports)

        var seen = Set<UInt16>()
        return ordered.filter { seen.insert($0).inserted }
    }

    private static func resolvedPreferredConnectionMode(
        _ mode: PreferredConnectionMode?,
        codexPorts: [UInt16],
        sshPort: UInt16?,
        websocketURL: String?
    ) -> PreferredConnectionMode? {
        switch mode {
        case .directCodex:
            return !codexPorts.isEmpty || websocketURL != nil ? .directCodex : nil
        case .ssh:
            return sshPort != nil ? .ssh : nil
        case nil:
            return nil
        }
    }

    private static func resolvedPreferredCodexPort(
        preferredConnectionMode: PreferredConnectionMode?,
        preferredCodexPort: UInt16?,
        codexPorts: [UInt16]
    ) -> UInt16? {
        guard preferredConnectionMode == .directCodex else { return nil }
        guard let preferredCodexPort, codexPorts.contains(preferredCodexPort) else { return nil }
        return preferredCodexPort
    }

    private static func normalizedHostKey(_ raw: String) -> String {
        var normalized = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")

        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        return normalized.lowercased()
    }

    private static func normalizedOpenCodeKey(_ raw: String) -> String {
        if let url = URL(string: raw), let scheme = url.scheme, !scheme.isEmpty {
            let host = (url.host ?? raw).lowercased()
            if let port = url.port {
                return "\(host):\(port)"
            }
            return host
        }

        return normalizedHostKey(raw)
    }
}
