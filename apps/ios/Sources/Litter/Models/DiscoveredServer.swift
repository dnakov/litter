import Foundation

enum ServerSource: Hashable {
    case local
    case bonjour
    case ssh
    case tailscale
    case manual

    var rawString: String {
        switch self {
        case .local: return "local"
        case .bonjour: return "bonjour"
        case .ssh: return "ssh"
        case .tailscale: return "tailscale"
        case .manual: return "manual"
        }
    }

    static func from(_ string: String) -> ServerSource {
        switch string {
        case "local": return .local
        case "bonjour": return .bonjour
        case "ssh": return .ssh
        case "tailscale": return .tailscale
        default: return .manual
        }
    }
}

struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let hostname: String
    let port: UInt16?
    let source: ServerSource
    let hasCodexServer: Bool

    var connectionTarget: ConnectionTarget? {
        if source == .local { return .local }
        if hasCodexServer, let port { return .remote(host: hostname, port: port) }
        return nil
    }
}
