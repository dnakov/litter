package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.litter.android.util.LLog
import java.security.GeneralSecurityException
import javax.crypto.AEADBadTagException

internal fun createRecoverableEncryptedPrefs(
    context: Context,
    prefsName: String,
    logTag: String,
): SharedPreferences {
    fun create(): SharedPreferences =
        EncryptedSharedPreferences.create(
            context,
            prefsName,
            MasterKey.Builder(context)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )

    return try {
        create()
    } catch (error: Exception) {
        if (!isRecoverableEncryptedPrefsError(error)) {
            throw error
        }

        LLog.e(
            logTag,
            "EncryptedSharedPreferences init failed; clearing corrupted store",
            error,
            fields = mapOf("prefsName" to prefsName),
        )
        runCatching { context.deleteSharedPreferences(prefsName) }
        create()
    }
}

private fun isRecoverableEncryptedPrefsError(error: Throwable): Boolean =
    error.causeSequence().any { cause ->
        cause is AEADBadTagException ||
            cause is GeneralSecurityException ||
            cause.javaClass.name.contains("KeyStoreException")
    }

private fun Throwable.causeSequence(): Sequence<Throwable> =
    generateSequence(this) { current -> current.cause }
