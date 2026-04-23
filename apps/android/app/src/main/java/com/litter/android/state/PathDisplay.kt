package com.litter.android.state

import android.content.Context

/**
 * Convert filesystem paths to short, user-facing strings.
 *
 * For **local** codex paths, rewrites the `HomeAnchor.path(context)` and
 * `$TMPDIR` to `~` and `/tmp` so the UI shows `~/projects/foo` and
 * `/tmp/x.txt` instead of the raw `/data/user/0/com.sigkitten.litter/files/...`
 * absolute paths.
 *
 * For **remote** paths, leaves the path as-is (remote filesystems have
 * their own natural home dirs like `/home/<user>`).
 */
object PathDisplay {
    /**
     * Callers pass [isLocal] `= true` only when [raw] is a path on the
     * in-process Android codex. Remote-server paths pass through unchanged.
     */
    fun display(raw: String, isLocal: Boolean, context: Context): String {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return if (isLocal) "~" else trimmed
        if (!isLocal) return trimmed
        val home = HomeAnchor.path(context)
        if (trimmed == home) return "~"
        if (trimmed.startsWith("$home/")) return "~/" + trimmed.substring(home.length + 1)
        val tmp = realTmp()
        if (tmp.isNotEmpty()) {
            if (trimmed == tmp) return "/tmp"
            if (trimmed.startsWith("$tmp/")) return "/tmp/" + trimmed.substring(tmp.length + 1)
        }
        return trimmed
    }

    /** Inverse of [display] for user-entered display strings on the local server. */
    fun expand(display: String, isLocal: Boolean, context: Context): String {
        if (!isLocal) return display
        if (display == "~") return HomeAnchor.path(context)
        if (display.startsWith("~/")) return HomeAnchor.path(context) + "/" + display.substring(2)
        val tmp = realTmp()
        if (tmp.isNotEmpty()) {
            if (display == "/tmp") return tmp
            if (display.startsWith("/tmp/")) return "$tmp/" + display.substring(5)
        }
        return display
    }

    private fun realTmp(): String {
        // Set by `Java_com_litter_android_core_bridge_UniffiInit_nativeBridgeInit`
        // at JNI boot. Strip trailing slash so comparisons are uniform.
        val raw = System.getenv("TMPDIR") ?: return ""
        return if (raw.endsWith("/")) raw.dropLast(1) else raw
    }
}
