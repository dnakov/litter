package com.litter.android.state

import android.content.Context
import android.system.Os
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

class OpenAIApiKeyStore(context: Context) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )

    fun hasStoredKey(): Boolean = !load().isNullOrBlank()

    fun load(): String? {
        val raw = prefs.getString(KEY_API_KEY, null)?.trim()
        return raw?.takeIf { it.isNotEmpty() }
    }

    fun save(apiKey: String) {
        val trimmed = apiKey.trim()
        prefs.edit().putString(KEY_API_KEY, trimmed).commit()
        applyToEnvironment()
    }

    fun clear() {
        prefs.edit().remove(KEY_API_KEY).commit()
        try {
            Os.unsetenv(ENV_KEY)
        } catch (_: Exception) {
        }
    }

    fun applyToEnvironment() {
        val key = load()
        try {
            if (key.isNullOrEmpty()) {
                Os.unsetenv(ENV_KEY)
            } else {
                Os.setenv(ENV_KEY, key, true)
            }
        } catch (_: Exception) {
        }
    }

    companion object {
        private const val PREFS_NAME = "litter_openai_api_key"
        private const val KEY_API_KEY = "openai_api_key"
        private const val ENV_KEY = "OPENAI_API_KEY"
    }
}
