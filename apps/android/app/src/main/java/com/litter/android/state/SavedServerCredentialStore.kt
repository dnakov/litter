package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

internal data class SavedServerCredentials(
    val username: String?,
    val password: String?,
) {
    fun isEmpty(): Boolean = username.isNullOrBlank() && password.isNullOrBlank()
}

internal class SavedServerCredentialStore(
    context: Context,
) {
    private val prefs: SharedPreferences? =
        runCatching {
            val appContext = context.applicationContext
            val masterKey =
                MasterKey
                    .Builder(appContext)
                    .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                    .build()
            EncryptedSharedPreferences.create(
                appContext,
                "litter_saved_server_credentials_secure",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
        }.getOrNull()

    val isAvailable: Boolean
        get() = prefs != null

    fun load(serverId: String): SavedServerCredentials? {
        val prefs = prefs ?: return null
        val key = keyFor(serverId)
        val username = prefs.getString("$key:username", null)?.trim()?.ifEmpty { null }
        val password = prefs.getString("$key:password", null)?.ifEmpty { null }
        val credentials = SavedServerCredentials(username = username, password = password)
        return credentials.takeUnless { it.isEmpty() }
    }

    fun save(
        serverId: String,
        credentials: SavedServerCredentials,
    ) {
        val prefs = prefs ?: return
        val key = keyFor(serverId)
        prefs.edit()
            .putString("$key:username", credentials.username)
            .putString("$key:password", credentials.password)
            .apply()
    }

    fun delete(serverId: String) {
        val prefs = prefs ?: return
        val key = keyFor(serverId)
        prefs.edit()
            .remove("$key:username")
            .remove("$key:password")
            .apply()
    }

    private fun keyFor(serverId: String): String = "saved_server:${serverId.trim()}"
}
