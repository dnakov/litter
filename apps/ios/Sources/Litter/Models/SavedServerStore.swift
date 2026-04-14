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
            if saved.backendKind == .openCode {
                return saved.normalizedForPersistence()
            }

            guard let server = saved.toDiscoveredServer() else {
                return saved.normalizedForPersistence()
            }
            let restored = SavedServer.from(server, rememberedByUser: saved.rememberedByUser)
                .normalizedForPersistence()
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
                    rememberedByUser: restored.rememberedByUser,
                    backendKind: restored.backendKind,
                    openCodeBaseURL: restored.openCodeBaseURL,
                    openCodeBasicAuthUsername: restored.openCodeBasicAuthUsername,
                    openCodeBasicAuthPassword: restored.openCodeBasicAuthPassword,
                    openCodeKnownDirectories: restored.openCodeKnownDirectories
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
        upsert(SavedServer.from(server))
    }

    static func upsert(_ server: SavedServer) {
        var saved = load()
        let existing = existingMatch(for: server, in: saved)
        saved.removeAll { entry in matches(server, entry) }
        saved.append(
            server.normalizedForPersistence().withRememberedByUser(existing?.rememberedByUser ?? server.rememberedByUser)
        )
        save(saved)
    }

    static func remember(_ server: DiscoveredServer) {
        remember(SavedServer.from(server, rememberedByUser: true))
    }

    static func remember(_ server: SavedServer) {
        var saved = load()
        saved.removeAll { entry in matches(server, entry) }
        saved.append(server.normalizedForPersistence().withRememberedByUser(true))
        save(saved)
    }

    static func rememberedServers() -> [SavedServer] {
        load().filter(\.rememberedByUser)
    }

    static func openCodeServers() -> [SavedServer] {
        load().filter { $0.backendKind == .openCode }
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
                    rememberedByUser: true,
                    backendKind: .codex,
                    opencodeBaseUrl: nil,
                    opencodeBasicAuthUsername: nil,
                    opencodeBasicAuthPassword: nil,
                    opencodeKnownDirectories: []
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
            rememberedByUser: old.rememberedByUser,
            backendKind: old.backendKind,
            openCodeBaseURL: old.openCodeBaseURL,
            openCodeBasicAuthUsername: old.openCodeBasicAuthUsername,
            openCodeBasicAuthPassword: old.openCodeBasicAuthPassword,
            openCodeKnownDirectories: old.openCodeKnownDirectories
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
            rememberedByUser: existing.rememberedByUser,
            backendKind: existing.backendKind,
            openCodeBaseURL: existing.openCodeBaseURL,
            openCodeBasicAuthUsername: existing.openCodeBasicAuthUsername,
            openCodeBasicAuthPassword: existing.openCodeBasicAuthPassword,
            openCodeKnownDirectories: existing.openCodeKnownDirectories
        )
        save(saved)
    }

    private static func existingMatch(for server: DiscoveredServer, in saved: [SavedServer]) -> SavedServer? {
        saved.first { matches(server, $0) }
    }

    private static func existingMatch(for server: SavedServer, in saved: [SavedServer]) -> SavedServer? {
        saved.first { matches(server, $0) }
    }

    private static func matches(_ server: DiscoveredServer, _ savedServer: SavedServer) -> Bool {
        guard let discovered = savedServer.toDiscoveredServer() else { return false }
        return savedServer.id == server.id || discovered.deduplicationKey == server.deduplicationKey
    }

    private static func matches(_ server: SavedServer, _ savedServer: SavedServer) -> Bool {
        savedServer.id == server.id || savedServer.deduplicationKey == server.deduplicationKey
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

private extension SavedServer {
    func withRememberedByUser(_ rememberedByUser: Bool) -> SavedServer {
        SavedServer(
            id: id,
            name: name,
            hostname: hostname,
            port: port,
            codexPorts: codexPorts,
            sshPort: sshPort,
            source: source,
            hasCodexServer: hasCodexServer,
            wakeMAC: wakeMAC,
            preferredConnectionMode: preferredConnectionMode,
            preferredCodexPort: preferredCodexPort,
            sshPortForwardingEnabled: sshPortForwardingEnabled,
            websocketURL: websocketURL,
            rememberedByUser: rememberedByUser,
            backendKind: backendKind,
            openCodeBaseURL: openCodeBaseURL,
            openCodeBasicAuthUsername: openCodeBasicAuthUsername,
            openCodeBasicAuthPassword: openCodeBasicAuthPassword,
            openCodeKnownDirectories: openCodeKnownDirectories
        )
    }
}
