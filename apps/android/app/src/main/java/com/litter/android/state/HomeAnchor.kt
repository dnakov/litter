package com.litter.android.state

import android.content.Context
import java.io.File

/**
 * Single source of truth for the user-facing `~` on the local Android codex.
 * Resolves to `filesDir/codex-home/workspace` — the same path the Rust
 * in-process bootstrap (`session/connection.rs::prepare_android_in_process_config`)
 * uses as the default local thread cwd.
 *
 * Used by `PathDisplay` to shorten absolute container paths to `~/…` and
 * by the local-server directory picker to scope navigation. Never used for
 * remote-server paths.
 */
object HomeAnchor {
    fun path(context: Context): String {
        val dir = File(File(context.applicationContext.filesDir, "codex-home"), "workspace")
        if (!dir.exists()) {
            dir.mkdirs()
        }
        return dir.absolutePath
    }
}
