import Foundation

enum ServerSource: String, Codable, Hashable {
    case local
    case bonjour
    case ssh
    case tailscale
    case manual

    init(_ source: FfiDiscoverySource) {
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

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let sshPort: UInt16?
    let source: ServerSource
    let hasCodexServer: Bool
    let wakeMAC: String?
    let sshPortForwardingEnabled: Bool
    let websocketURL: String?

    init(
        id: String,
        name: String,
        hostname: String,
        port: UInt16?,
        sshPort: UInt16? = nil,
        source: ServerSource,
        hasCodexServer: Bool,
        wakeMAC: String? = nil,
        sshPortForwardingEnabled: Bool = false,
        websocketURL: String? = nil
    ) {
        self.id = id
        self.name = name
        self.hostname = hostname
        self.port = port
        self.sshPort = sshPort
        self.source = source
        self.hasCodexServer = hasCodexServer
        self.wakeMAC = Self.normalizeWakeMAC(wakeMAC)
        self.sshPortForwardingEnabled = sshPortForwardingEnabled
        self.websocketURL = websocketURL
    }

    var connectionTarget: ConnectionTarget? {
        if source == .local { return .local }
        if let websocketURL, let url = URL(string: websocketURL) { return .remoteURL(url) }
        if hasCodexServer, let port { return .remote(host: hostname, port: port) }
        return nil
    }

    var resolvedSSHPort: UInt16 {
        sshPort ?? 22
    }

    var deduplicationKey: String {
        if source == .local {
            return "local"
        }

        if let websocketURL, let url = URL(string: websocketURL) {
            let host = Self.normalizedHostKey(url.host ?? hostname)
            return host.isEmpty ? id : host
        }

        let host = Self.normalizedHostKey(hostname)
        return host.isEmpty ? id : host
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
}
