import Foundation
import Observation

/// Persists user-defined local nicknames for sessions keyed by serverId:threadId.
/// Nicknames are stored on-device only and never synced to the server.
@MainActor
@Observable
final class LocalSessionNicknames {
    private let defaultsKey = "localSessionNicknames"
    private(set) var nicknames: [String: String]

    init() {
        nicknames = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    func set(_ nickname: String, for threadKey: ThreadKey) {
        let k = storageKey(for: threadKey)
        if nickname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            nicknames.removeValue(forKey: k)
        } else {
            nicknames[k] = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        UserDefaults.standard.set(nicknames, forKey: defaultsKey)
    }

    func nickname(for threadKey: ThreadKey) -> String? {
        nicknames[storageKey(for: threadKey)]
    }

    private func storageKey(for key: ThreadKey) -> String {
        "\(key.serverId):\(key.threadId)"
    }
}
