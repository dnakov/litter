package com.litter.android.state

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Opens an [EncryptedSharedPreferences] file, recovering from the Tink/Keystore
 * mismatch that happens when Android Auto-Backup restores the ciphertext but
 * the Keystore master key is fresh — common after uninstall/reinstall across
 * signing keys. On decryption failure we wipe only this prefs file; a fresh
 * Tink keyset is then generated and encrypted with the current master key.
 *
 * We intentionally do NOT delete the keystore master key on failure. The
 * master key alias is shared across every encrypted prefs file in the app,
 * so deleting it would invalidate the other stores' keysets and every launch
 * would cascade into wiping them all — credentials would never persist past
 * a single session.
 */
internal fun openEncryptedPrefsOrReset(
    context: Context,
    name: String,
): SharedPreferences {
    return runCatching { buildEncryptedPrefs(context, name) }.getOrElse {
        context.deleteSharedPreferences(name)
        buildEncryptedPrefs(context, name)
    }
}

private fun buildEncryptedPrefs(context: Context, name: String): SharedPreferences =
    EncryptedSharedPreferences.create(
        context,
        name,
        MasterKey.Builder(context)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
    )
