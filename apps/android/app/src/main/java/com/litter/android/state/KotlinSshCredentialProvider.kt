package com.litter.android.state

import uniffi.codex_mobile_client.SshAuthMethodRecord
import uniffi.codex_mobile_client.SshCredentialProvider
import uniffi.codex_mobile_client.SshCredentialRecord

class KotlinSshCredentialProvider(private val store: SshCredentialStore) : SshCredentialProvider {
    override fun loadCredential(host: String, port: UShort): SshCredentialRecord? {
        val saved = store.load(host, port.toInt()) ?: return null
        return SshCredentialRecord(
            username = saved.username,
            authMethod = when (saved.method) {
                SshAuthMethod.PASSWORD -> SshAuthMethodRecord.PASSWORD
                SshAuthMethod.KEY -> SshAuthMethodRecord.KEY
            },
            password = saved.password,
            privateKeyPem = saved.privateKey,
            passphrase = saved.passphrase,
        )
    }
}
