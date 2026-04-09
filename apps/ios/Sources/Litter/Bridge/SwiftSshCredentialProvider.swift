import Foundation

final class SwiftSshCredentialProvider: SshCredentialProvider {
    func loadCredential(host: String, port: UInt16) -> SshCredentialRecord? {
        guard let saved = try? SSHCredentialStore.shared.load(host: host, port: Int(port)) else {
            return nil
        }
        return SshCredentialRecord(
            username: saved.username,
            authMethod: saved.method == .password ? .password : .key,
            password: saved.password,
            privateKeyPem: saved.privateKey,
            passphrase: saved.passphrase
        )
    }
}
