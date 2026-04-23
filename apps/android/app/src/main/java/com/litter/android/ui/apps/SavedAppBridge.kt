package com.litter.android.ui.apps

import android.content.Context
import android.webkit.JavascriptInterface
import com.litter.android.state.SavedAppsStore

/**
 * Android-side implementation of the app-mode WebView bridge. The injected JS
 * shell calls `window.__LitterAppBridge.saveAppState(payloadJson, schema)`
 * whenever user state needs to be persisted; this forwards that into the
 * [SavedAppsStore] debouncer. `window.__LitterAppBridge.structuredResponse(...)`
 * forwards app-mode `window.structuredResponse({prompt, responseFormat})` calls
 * up to the Composable host, which dispatches them to the Rust mobile client
 * and replies via `evaluateJavascript`.
 *
 * The name `__LitterAppBridge` is the single symbol the JS shell references on
 * Android. iOS uses `window.webkit.messageHandlers.widget.postMessage` and the
 * shell branches between the two — keep this interface name in sync with the
 * `wrapWidgetHtml` injection.
 */
class SavedAppBridge(
    context: Context,
    val appId: String,
    private val onStructuredRequest: ((
        requestId: String,
        prompt: String,
        schemaJson: String,
    ) -> Unit)? = null,
) {
    private val appContext = context.applicationContext

    @JavascriptInterface
    fun saveAppState(payload: String, schema: Int) {
        val clampedSchema = if (schema < 0) 0u else schema.toUInt()
        SavedAppsStore.saveState(appContext, appId, payload, clampedSchema)
    }

    @JavascriptInterface
    fun structuredResponse(requestId: String, prompt: String, schemaJson: String) {
        onStructuredRequest?.invoke(requestId, prompt, schemaJson)
    }

    companion object {
        /** JS interface name exposed via `WebView.addJavascriptInterface`. */
        const val INTERFACE_NAME = "__LitterAppBridge"
    }
}
