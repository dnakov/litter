package com.litter.android.state

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

internal data class BundledAuthTokens(
    val accessToken: String,
    val idToken: String,
    val refreshToken: String?,
    val chatgptAccountId: String,
    val chatgptPlanType: String?,
)

internal class BundledAuthStore(context: Context) {
    private val prefs =
        EncryptedSharedPreferences.create(
            context,
            PREFS_NAME,
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    fun save(tokens: BundledAuthTokens) {
        prefs.edit()
            .putString(KEY_ACCESS_TOKEN, tokens.accessToken)
            .putString(KEY_ID_TOKEN, tokens.idToken)
            .putString(KEY_REFRESH_TOKEN, tokens.refreshToken)
            .putString(KEY_ACCOUNT_ID, tokens.chatgptAccountId)
            .putString(KEY_PLAN_TYPE, tokens.chatgptPlanType)
            .apply()
    }

    fun load(): BundledAuthTokens? {
        val accessToken = prefs.getString(KEY_ACCESS_TOKEN, null)?.trim().orEmpty()
        val idToken = prefs.getString(KEY_ID_TOKEN, null)?.trim().orEmpty()
        val accountId = prefs.getString(KEY_ACCOUNT_ID, null)?.trim().orEmpty()
        if (accessToken.isEmpty() || idToken.isEmpty() || accountId.isEmpty()) {
            return null
        }
        return BundledAuthTokens(
            accessToken = accessToken,
            idToken = idToken,
            refreshToken = prefs.getString(KEY_REFRESH_TOKEN, null)?.trim()?.ifEmpty { null },
            chatgptAccountId = accountId,
            chatgptPlanType = prefs.getString(KEY_PLAN_TYPE, null)?.trim()?.ifEmpty { null },
        )
    }

    fun clear() {
        prefs.edit().clear().apply()
    }

    private companion object {
        private const val PREFS_NAME = "bundled_auth_tokens"
        private const val KEY_ACCESS_TOKEN = "access_token"
        private const val KEY_ID_TOKEN = "id_token"
        private const val KEY_REFRESH_TOKEN = "refresh_token"
        private const val KEY_ACCOUNT_ID = "chatgpt_account_id"
        private const val KEY_PLAN_TYPE = "chatgpt_plan_type"
    }
}
