import Foundation

actor SshSessionStore {
    static let shared = SshSessionStore()

    private var sessionIdsByServerId: [String: String] = [:]

    func record(sessionId: String, for serverId: String) {
        sessionIdsByServerId[serverId] = sessionId
    }

    func clear(serverId: String) {
        sessionIdsByServerId.removeValue(forKey: serverId)
    }

    func close(serverId: String, ssh: SshBridge) async {
        guard let sessionId = sessionIdsByServerId.removeValue(forKey: serverId) else { return }
        try? await ssh.sshClose(sessionId: sessionId)
    }
}
