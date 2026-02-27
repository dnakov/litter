import Foundation

struct RecentDirectoryEntry: Codable, Identifiable, Hashable {
    let serverId: String
    let path: String
    let lastUsedAt: Date
    let useCount: Int

    var id: String {
        "\(serverId)|\(path)"
    }
}

@MainActor
final class RecentDirectoryStore {
    static let shared = RecentDirectoryStore()

    private let userDefaults: UserDefaults
    private let storageKey = "recent_directories_v1"
    private let maxEntriesPerServer = 20

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func recentDirectories(for serverId: String, limit: Int = 8) -> [RecentDirectoryEntry] {
        let normalizedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerId.isEmpty else { return [] }
        return loadAll()
            .filter { $0.serverId == normalizedServerId }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
            .prefix(limit)
            .map { $0 }
    }

    @discardableResult
    func record(path: String, for serverId: String, limit: Int = 8) -> [RecentDirectoryEntry] {
        let normalizedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerId.isEmpty else { return [] }
        let normalizedPath = normalizePath(path)
        guard !normalizedPath.isEmpty else { return recentDirectories(for: normalizedServerId, limit: limit) }

        var all = loadAll()
        let now = Date()

        if let index = all.firstIndex(where: { $0.serverId == normalizedServerId && $0.path == normalizedPath }) {
            let existing = all[index]
            all[index] = RecentDirectoryEntry(
                serverId: normalizedServerId,
                path: normalizedPath,
                lastUsedAt: now,
                useCount: existing.useCount + 1
            )
        } else {
            all.append(
                RecentDirectoryEntry(
                    serverId: normalizedServerId,
                    path: normalizedPath,
                    lastUsedAt: now,
                    useCount: 1
                )
            )
        }

        all = trimEntries(all)
        saveAll(all)
        return recentDirectories(for: normalizedServerId, limit: limit)
    }

    @discardableResult
    func remove(path: String, for serverId: String, limit: Int = 8) -> [RecentDirectoryEntry] {
        let normalizedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerId.isEmpty else { return [] }
        let normalizedPath = normalizePath(path)
        var all = loadAll()
        all.removeAll { $0.serverId == normalizedServerId && $0.path == normalizedPath }
        saveAll(all)
        return recentDirectories(for: normalizedServerId, limit: limit)
    }

    @discardableResult
    func clear(for serverId: String, limit _: Int = 8) -> [RecentDirectoryEntry] {
        let normalizedServerId = serverId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedServerId.isEmpty else { return [] }
        var all = loadAll()
        all.removeAll { $0.serverId == normalizedServerId }
        saveAll(all)
        return []
    }

    private func loadAll() -> [RecentDirectoryEntry] {
        guard let data = userDefaults.data(forKey: storageKey) else { return [] }
        do {
            return try JSONDecoder().decode([RecentDirectoryEntry].self, from: data)
        } catch {
            return []
        }
    }

    private func saveAll(_ entries: [RecentDirectoryEntry]) {
        do {
            let data = try JSONEncoder().encode(entries)
            userDefaults.set(data, forKey: storageKey)
        } catch {}
    }

    private func trimEntries(_ entries: [RecentDirectoryEntry]) -> [RecentDirectoryEntry] {
        var grouped: [String: [RecentDirectoryEntry]] = [:]
        for entry in entries {
            grouped[entry.serverId, default: []].append(entry)
        }

        var trimmed: [RecentDirectoryEntry] = []
        for (_, serverEntries) in grouped {
            let sorted = serverEntries.sorted { $0.lastUsedAt > $1.lastUsedAt }
            trimmed.append(contentsOf: sorted.prefix(maxEntriesPerServer))
        }
        return trimmed
    }

    private func normalizePath(_ path: String) -> String {
        var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.isEmpty { return "" }
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized
    }
}
