package com.litter.android.state

import android.content.Context
import java.io.File

/**
 * Directory that holds the shared Rust preferences file. Points at the
 * app's internal files dir today; future cloud sync can route this to a
 * Drive app-data mirror directory without the rest of the app caring.
 */
object MobilePreferencesDirectory {
    fun path(context: Context): String {
        val dir = File(context.applicationContext.filesDir, "LitterPreferences")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir.absolutePath
    }
}
