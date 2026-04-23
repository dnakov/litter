import Foundation

/// Thin Swift wrapper around the Rust `preferences_*` functions. Rust owns
/// the storage format and (later) cloud-sync policy; Swift just picks the
/// directory and exposes a Swift-shaped API to the rest of the app.
@MainActor
enum SavedThreadsStore {
    static func pinnedKeys() -> [PinnedThreadKey] {
        preferencesLoad(directory: MobilePreferencesDirectory.path).pinnedThreads
    }

    static func add(_ key: PinnedThreadKey) {
        _ = preferencesAddPinnedThread(directory: MobilePreferencesDirectory.path, key: key)
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
    }

    static func remove(_ key: PinnedThreadKey) {
        _ = preferencesRemovePinnedThread(directory: MobilePreferencesDirectory.path, key: key)
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
    }

    static func contains(_ key: PinnedThreadKey) -> Bool {
        pinnedKeys().contains(key)
    }

    static func hiddenKeys() -> [PinnedThreadKey] {
        preferencesLoad(directory: MobilePreferencesDirectory.path).hiddenThreads
    }

    static func hide(_ key: PinnedThreadKey) {
        _ = preferencesAddHiddenThread(directory: MobilePreferencesDirectory.path, key: key)
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
    }

    static func unhide(_ key: PinnedThreadKey) {
        _ = preferencesRemoveHiddenThread(directory: MobilePreferencesDirectory.path, key: key)
        CloudKVSBridge.shared.notifyRustPreferencesChanged()
    }

    /// Compatibility shim for the old `PinnedKey` type used elsewhere in the
    /// app — delegates to the Rust-generated `PinnedThreadKey`.
    typealias PinnedKey = PinnedThreadKey
}

extension PinnedThreadKey {
    init(threadKey: ThreadKey) {
        self.init(serverId: threadKey.serverId, threadId: threadKey.threadId)
    }

    var threadKey: ThreadKey {
        ThreadKey(serverId: serverId, threadId: threadId)
    }
}
