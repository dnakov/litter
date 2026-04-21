package com.litter.android.state

import android.content.Context
import org.json.JSONObject

enum class SshAuthMethod {
    PASSWORD,
    KEY,
}

data class SavedSshCredential(
    val username: String,
    val method: SshAuthMethod,
    val password: String? = null,
    val privateKey: String? = null,
    val passphrase: String? = null,
) {
    fun toJson(): String = JSONObject().apply {
        put("username", username)
        put("method", method.name)
        password?.let { put("password", it) }
        privateKey?.let { put("privateKey", it) }
        passphrase?.let { put("passphrase", it) }
    }.toString()

    companion object {
        fun fromJson(raw: String): SavedSshCredential {
            val obj = JSONObject(raw)
            return SavedSshCredential(
                username = obj.getString("username"),
                method = SshAuthMethod.valueOf(obj.getString("method")),
                password = obj.optString("password").takeIf { it.isNotBlank() },
                privateKey = obj.optString("privateKey").takeIf { it.isNotBlank() },
                passphrase = obj.optString("passphrase").takeIf { it.isNotBlank() },
            )
        }
    }
}

class SshCredentialStore(context: Context) {
    private val prefs = openEncryptedPrefsOrReset(context, PREFS_NAME)

    fun load(host: String, port: Int): SavedSshCredential? {
        val raw = prefs.getString(key(host, port), null) ?: return null
        return try {
            SavedSshCredential.fromJson(raw)
        } catch (_: Exception) {
            null
        }
    }

    fun save(host: String, port: Int, credential: SavedSshCredential) {
        prefs.edit().putString(key(host, port), credential.toJson()).apply()
    }

    fun delete(host: String, port: Int) {
        prefs.edit().remove(key(host, port)).apply()
    }

    private fun key(host: String, port: Int): String {
        val normalizedHost = host.trim().trimStart('[').trimEnd(']').lowercase()
        return "$normalizedHost:$port"
    }

    companion object {
        private const val PREFS_NAME = "litter_ssh_credentials"
    }
}
