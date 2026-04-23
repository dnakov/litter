package com.litter.android.state

import android.content.Context
import java.io.File

/**
 * Directory that holds saved-app files (`saved_apps.json`, `html/<id>.html`,
 * `state/<id>.json`) under `filesDir/Apps/`. Saved apps are user content,
 * so they live alongside user-facing session data — parallel to iOS'
 * `Documents/Apps/`.
 *
 * Rust `saved_apps.rs` writes directly under whatever path it receives
 * (no `apps/` suffix). Pass `SavedAppsDirectory.path(context)` into every
 * `savedApp*(directory=...)` call.
 */
object SavedAppsDirectory {
    fun path(context: Context): String {
        val dir = File(context.applicationContext.filesDir, "Apps")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir.absolutePath
    }
}
