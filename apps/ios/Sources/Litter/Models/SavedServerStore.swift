import Foundation
import UIKit

@MainActor
enum SavedServerStore {
    private static let savedServersKey = "codex_saved_servers"

    static func save(_ servers: [SavedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        UserDefaults.standard.set(data, forKey: savedServersKey)
    }

    static func load() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: savedServersKey) else { return [] }
        let decoded = (try? JSONDecoder().decode([SavedServer].self, from: data)) ?? []
        let migrated = decoded.map { saved -> SavedServer in
            let server = saved.toDiscoveredServer()
            let restored = SavedServer.from(server, rememberedByUser: saved.rememberedByUser)
            if shouldReplaceLegacyLocalPlaceholder(restored) {
                return SavedServer(
                    id: restored.id,
                    name: UIDevice.current.name,
                    hostname: restored.hostname,
                    port: restored.port,
                    codexPorts: restored.codexPorts,
                    sshPort: restored.sshPort,
                    source: restored.source,
                    hasCodexServer: restored.hasCodexServer,
                    wakeMAC: restored.wakeMAC,
                    preferredConnectionMode: restored.preferredConnectionMode,
                    preferredCodexPort: restored.preferredCodexPort,
                    sshPortForwardingEnabled: restored.sshPortForwardingEnabled,
                    websocketURL: restored.websocketURL,
                    rememberedByUser: restored.rememberedByUser
                )
            }
            return restored
        }
        if migrated != decoded {
            save(migrated)
        }
        return migrated
    }

    static func upsert(_ server: DiscoveredServer) {
        var saved = load()
        let existing = existingMatch(for: server, in: saved)
        saved.removeAll { entry in matches(server, entry) }
        saved.append(
            SavedServer.from(
                server,
                rememberedByUser: existing?.rememberedByUser ?? false
            )
        )
        save(saved)
    }

    static func remember(_ server: DiscoveredServer) {
        var saved = load()
        saved.removeAll { entry in matches(server, entry) }
        saved.append(SavedServer.from(server, rememberedByUser: true))
        save(saved)
    }

    static func rememberedServers() -> [SavedServer] {
        load().filter(\.rememberedByUser)
    }

    static func reconnectRecords(
        localDisplayName: String,
        rememberedOnly: Bool = false
    ) -> [SavedServerRecord] {
        let saved = rememberedOnly ? rememberedServers() : load()
        var records = saved.map { $0.toRecord() }
        if records.contains(where: { $0.id == "local" || $0.source == ServerSource.local.rawValue }) == false {
            records.append(
                SavedServerRecord(
                    id: "local",
                    name: localDisplayName,
                    hostname: "127.0.0.1",
                    port: 0,
                    codexPorts: [],
                    sshPort: nil,
                    source: ServerSource.local.rawValue,
                    hasCodexServer: true,
                    wakeMac: nil,
                    preferredConnectionMode: nil,
                    preferredCodexPort: nil,
                    sshPortForwardingEnabled: nil,
                    websocketUrl: nil,
                    rememberedByUser: true
                )
            )
        }
        return records
    }

    static func remove(serverId: String) {
        var saved = load()
        saved.removeAll { $0.id == serverId }
        save(saved)
    }

    static func rename(serverId: String, newName: String) {
        var saved = load()
        guard let index = saved.firstIndex(where: { $0.id == serverId }) else { return }
        let old = saved[index]
        saved[index] = SavedServer(
            id: old.id,
            name: newName,
            hostname: old.hostname,
            port: old.port,
            codexPorts: old.codexPorts,
            sshPort: old.sshPort,
            source: old.source,
            hasCodexServer: old.hasCodexServer,
            wakeMAC: old.wakeMAC,
            preferredConnectionMode: old.preferredConnectionMode,
            preferredCodexPort: old.preferredCodexPort,
            sshPortForwardingEnabled: old.sshPortForwardingEnabled,
            websocketURL: old.websocketURL,
            rememberedByUser: old.rememberedByUser
        )
        save(saved)
    }

    static func updateWakeMAC(serverId: String, host: String, wakeMAC: String?) {
        guard let normalizedWakeMAC = DiscoveredServer.normalizeWakeMAC(wakeMAC) else { return }

        var saved = load()
        guard let index = saved.firstIndex(where: { entry in
            entry.id == serverId || normalizedHost(entry.hostname) == normalizedHost(host)
        }) else {
            return
        }

        let existing = saved[index]
        guard existing.wakeMAC != normalizedWakeMAC else { return }

        saved[index] = SavedServer(
            id: existing.id,
            name: existing.name,
            hostname: existing.hostname,
            port: existing.port,
            codexPorts: existing.codexPorts,
            sshPort: existing.sshPort,
            source: existing.source,
            hasCodexServer: existing.hasCodexServer,
            wakeMAC: normalizedWakeMAC,
            preferredConnectionMode: existing.preferredConnectionMode,
            preferredCodexPort: existing.preferredCodexPort,
            sshPortForwardingEnabled: existing.sshPortForwardingEnabled,
            websocketURL: existing.websocketURL,
            rememberedByUser: existing.rememberedByUser
        )
        save(saved)
    }

    private static func existingMatch(for server: DiscoveredServer, in saved: [SavedServer]) -> SavedServer? {
        saved.first { matches(server, $0) }
    }

    private static func matches(_ server: DiscoveredServer, _ savedServer: SavedServer) -> Bool {
        savedServer.id == server.id || savedServer.toDiscoveredServer().deduplicationKey == server.deduplicationKey
    }

    private static func normalizedHost(_ host: String) -> String {
        var normalized = host
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            .replacingOccurrences(of: "%25", with: "%")

        if !normalized.contains(":"), let scopeIndex = normalized.firstIndex(of: "%") {
            normalized = String(normalized[..<scopeIndex])
        }

        return normalized.lowercased()
    }

    private static func shouldReplaceLegacyLocalPlaceholder(_ server: SavedServer) -> Bool {
        server.source == .local
            && server.name.trimmingCharacters(in: .whitespacesAndNewlines) == "This Device"
    }
}
