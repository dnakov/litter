package com.litter.android.ui.conversation

import android.webkit.JavascriptInterface

/**
 * JavaScript-to-Kotlin bridge for the timeline widget shell. Mirrors the
 * `{_type, ...}` messages that the iOS shell posts through
 * `window.webkit.messageHandlers.widget.postMessage(...)`. Every method maps
 * to one of those dispatches.
 *
 * The shell JS uses a `__postWidgetMessage` helper that prefers
 * `window.webkit.messageHandlers.widget` if present and otherwise calls the
 * method on `window.[INTERFACE_NAME]` — so one shell ships cross-platform.
 *
 * Callbacks run on the WebView's JavaScript thread; handlers must forward to
 * the main/UI thread before touching Compose state.
 */
class WidgetBridge(
    private val onHeight: (Int) -> Unit,
    private val onSendPrompt: (String) -> Unit,
    private val onOpenLink: (String) -> Unit,
    private val onReady: () -> Unit,
) {
    @JavascriptInterface
    fun height(value: Int) {
        if (value > 0) onHeight(value)
    }

    @JavascriptInterface
    fun sendPrompt(text: String) {
        val trimmed = text.trim()
        if (trimmed.isNotEmpty()) onSendPrompt(trimmed)
    }

    @JavascriptInterface
    fun openLink(url: String) {
        if (url.isNotBlank()) onOpenLink(url)
    }

    /**
     * Fired by the shell's morphdom `<script onload>` once `window._morphReady`
     * flips to `true` and any buffered content has been flushed. Host code
     * uses this to know the WebView is ready for `evaluateJavascript` pushes.
     */
    @JavascriptInterface
    fun ready() {
        onReady()
    }

    companion object {
        const val INTERFACE_NAME = "__LitterWidgetBridge"
    }
}
