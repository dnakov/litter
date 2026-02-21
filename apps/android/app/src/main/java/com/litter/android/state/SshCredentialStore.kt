package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONObject

enum class SshAuthMethod {
    PASSWORD,
    KEY,
}

data class SavedSshCredential(
    val username: String,
    val method: SshAuthMethod,
    val password: String?,
    val privateKey: String?,
    val passphrase: String?,
)

class SshCredentialStore(
    context: Context,
) {
    private val appContext = context.applicationContext
    private val prefs: SharedPreferences =
        runCatching {
            val masterKey =
                MasterKey
                    .Builder(appContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
            EncryptedSharedPreferences.create(
                appContext,
                "litter_ssh_credentials_secure",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrElse {
            // Fallback for environments where encrypted prefs initialization fails.
            appContext.getSharedPreferences("litter_ssh_credentials", Context.MODE_PRIVATE)
        }

    fun load(
        host: String,
        port: Int = 22,
    ): SavedSshCredential? {
        val raw = prefs.getString(keyFor(host, port), null) ?: return null
        return runCatching {
            val json = JSONObject(raw)
            SavedSshCredential(
                username = json.optString("username").trim(),
                method = SshAuthMethod.valueOf(json.optString("method").trim().ifEmpty { "PASSWORD" }),
                password = json.optString("password").trim().ifEmpty { null },
                privateKey = json.optString("privateKey").ifEmpty { null },
                passphrase = json.optString("passphrase").ifEmpty { null },
            )
        }.getOrNull()
    }

    fun save(
        host: String,
        port: Int = 22,
        credential: SavedSshCredential,
    ) {
        val json =
            JSONObject()
                .put("username", credential.username)
                .put("method", credential.method.name)
                .put("password", credential.password ?: JSONObject.NULL)
                .put("privateKey", credential.privateKey ?: JSONObject.NULL)
                .put("passphrase", credential.passphrase ?: JSONObject.NULL)

        prefs.edit().putString(keyFor(host, port), json.toString()).apply()
    }

    fun delete(
        host: String,
        port: Int = 22,
    ) {
        prefs.edit().remove(keyFor(host, port)).apply()
    }

    private fun keyFor(
        host: String,
        port: Int,
    ): String {
        return "cred:${normalizeHost(host).lowercase()}:$port"
    }

    private fun normalizeHost(host: String): String {
        var normalized =
            host
                .trim()
                .trim('[')
                .trim(']')
                .replace("%25", "%")

        if (!normalized.contains(':')) {
            val scopeIndex = normalized.indexOf('%')
            if (scopeIndex >= 0) {
                normalized = normalized.substring(0, scopeIndex)
            }
        }

        return normalized
    }
}
