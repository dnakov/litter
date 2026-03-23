import Foundation

@MainActor
enum SavedServerStore {
    private static let savedServersKey = "codex_saved_servers"

    static func save(_ servers: [SavedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: savedServersKey)
    }

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        return (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
    }

    static func upsert(_ server: DiscoveredServer) {
        var saved = load()
        saved.removeAll { existing in
            existing.id == server.id || existing.toDiscoveredServer().deduplicationKey == server.deduplicationKey
        }
        saved.append(SavedServer.from(server))
        save(saved)
    }

    static func remove(serverId: String) {
        var saved = load()
        saved.removeAll { $0.id == serverId }
        save(saved)
    }
}
