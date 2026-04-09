package com.litter.android.state

import android.content.Context
import uniffi.codex_mobile_client.ThreadKey

/**
 * Handles app lifecycle events: server reconnection on resume,
 * background turn tracking on pause, and push notification handling.
 *
 * Reconnect orchestration is delegated to the shared Rust [ReconnectController].
 */
class AppLifecycleController {

    /** Threads that were active when the app went to background. */
    private val backgroundedTurnKeys = mutableSetOf<ThreadKey>()

    /** FCM device push token. */
    var devicePushToken: String? = null
        private set

    fun setDevicePushToken(token: String) {
        devicePushToken = token
    }

    /**
     * Reconnects all saved servers on app launch or resume.
     */
    suspend fun reconnectSavedServers(context: Context, appModel: AppModel) {
        val servers = SavedServerStore.remembered(context).map { it.toRecord() }
        appModel.reconnectController.syncSavedServers(servers)
        val results = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, results)
        appModel.refreshSnapshot()
    }

    /**
     * Reconnects a single server by ID.
     */
    suspend fun reconnectServer(context: Context, appModel: AppModel, serverId: String) {
        val servers = SavedServerStore.load(context).map { it.toRecord() }
        appModel.reconnectController.syncSavedServers(servers)
        val result = appModel.reconnectController.reconnectServer(serverId)
        restoreLocalStateAfterReconnect(appModel, listOf(result))
        appModel.refreshSnapshot()
    }

    /**
     * Called when the app enters the foreground.
     */
    suspend fun onResume(context: Context, appModel: AppModel) {
        val servers = SavedServerStore.remembered(context).map { it.toRecord() }
        appModel.reconnectController.syncSavedServers(servers)
        val results = appModel.reconnectController.onAppBecameActive()
        restoreLocalStateAfterReconnect(appModel, results)
        backgroundedTurnKeys.clear()
        appModel.refreshSnapshot()
    }

    /**
     * Called when the background foreground-service starts monitoring active turns.
     * The app is still backgrounded, so this must not mark the shared store active.
     */
    suspend fun onBackgroundServiceStart(context: Context, appModel: AppModel) {
        val servers = SavedServerStore.remembered(context).map { it.toRecord() }
        appModel.reconnectController.syncSavedServers(servers)
        appModel.reconnectController.onAppEnteredBackground()
        val results = appModel.reconnectController.reconnectSavedServers()
        restoreLocalStateAfterReconnect(appModel, results)
        appModel.refreshSnapshot()
    }

    /**
     * Called when the app goes to background.
     * Tracks active turns for notification on completion.
     */
    fun onPause(appModel: AppModel) {
        appModel.reconnectController.onAppEnteredBackground()
        backgroundedTurnKeys.clear()
        val snap = appModel.snapshot.value ?: return
        for (thread in snap.threads) {
            if (thread.activeTurnId != null) {
                backgroundedTurnKeys.add(thread.key)
            }
        }
    }

    /**
     * Returns the set of threads that were active when the app was backgrounded.
     * Used by foreground service / push handler to know what to track.
     */
    fun getBackgroundedTurnKeys(): Set<ThreadKey> = backgroundedTurnKeys.toSet()

    private suspend fun restoreLocalStateAfterReconnect(
        appModel: AppModel,
        results: List<uniffi.codex_mobile_client.ReconnectResult>,
    ) {
        for (result in results) {
            if (!result.needsLocalAuthRestore) {
                continue
            }
            appModel.restoreStoredLocalChatGptAuth(result.serverId)
            runCatching {
                appModel.refreshSessions(listOf(result.serverId))
            }
        }
    }
}
