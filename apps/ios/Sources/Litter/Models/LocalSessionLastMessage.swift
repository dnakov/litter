import Foundation
import Observation

/// Caches the last assistant message for each session, persisted to UserDefaults.
/// Populated when a thread is opened and items stream in. Used to show a preview
/// on the session list without requiring the thread to be open.
@MainActor
@Observable
final class LocalSessionLastMessage {
    private let defaultsKey = "localSessionLastMessages"
    private(set) var messages: [String: String]

    init() {
        messages = (UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String]) ?? [:]
    }

    func update(_ text: String, for threadKey: ThreadKey) {
        let snippet = String(text.prefix(200))
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !snippet.isEmpty else { return }
        let k = storageKey(for: threadKey)
        guard messages[k] != snippet else { return }
        messages[k] = snippet
        UserDefaults.standard.set(messages, forKey: defaultsKey)
    }

    func lastMessage(for threadKey: ThreadKey) -> String? {
        messages[storageKey(for: threadKey)]
    }

    private func storageKey(for key: ThreadKey) -> String {
        "\(key.serverId):\(key.threadId)"
    }
}
