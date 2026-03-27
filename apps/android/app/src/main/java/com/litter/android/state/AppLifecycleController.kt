package com.litter.android.state

import android.content.Context
import android.util.Log
import kotlinx.coroutines.sync.Mutex
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.AppServerHealth

/**
 * Handles app lifecycle events: server reconnection on resume,
 * background turn tracking on pause, and push notification handling.
 */
class AppLifecycleController {
    private val reconnectMutex = Mutex()

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
        if (!reconnectMutex.tryLock()) {
            Log.d("AppLifecycleController", "reconnect already in progress; skipping")
            return
        }
        try {
            val saved = SavedServerStore.load(context)
            val sshCredentials = SshCredentialStore(context)
            val activeServerIds = appModel.store.snapshot()
                .servers
                .filter { it.health != AppServerHealth.DISCONNECTED }
                .mapTo(mutableSetOf()) { it.serverId }
            for (server in saved) {
                if (server.id in activeServerIds) {
                    Log.d("AppLifecycleController", "server already active; skipping reconnect ${server.id}")
                    continue
                }
                try {
                    when {
                        server.source == "local" -> {
                            appModel.serverBridge.connectLocalServer(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.port.toUShort(),
                            )
                            appModel.restoreStoredLocalChatGptAuth(server.id)
                        }
                        server.websocketURL != null -> {
                            appModel.serverBridge.connectRemoteUrlServer(
                                serverId = server.id,
                                displayName = server.name,
                                websocketUrl = server.websocketURL!!,
                            )
                        }
                        server.resolvedPreferredConnectionMode == "ssh" -> {
                            val credential =
                                sshCredentials.load(server.hostname, server.resolvedSshPort) ?: continue
                            reconnectSshServer(appModel, server, credential)
                        }
                        server.directCodexPort != null -> {
                            appModel.serverBridge.connectRemoteServer(
                                serverId = server.id,
                                displayName = server.name,
                                host = server.hostname,
                                port = server.directCodexPort!!.toUShort(),
                            )
                        }
                        else -> {
                            Log.d("AppLifecycleController", "skipping reconnect for ${server.id}; no valid saved transport")
                            continue
                        }
                    }
                    activeServerIds.add(server.id)
                } catch (_: Exception) {
                    // Best-effort reconnection — server may be offline
                }
            }
            appModel.refreshSnapshot()
        } finally {
            reconnectMutex.unlock()
        }
    }

    private suspend fun reconnectSshServer(
        appModel: AppModel,
        server: SavedServer,
        credential: SavedSshCredential,
    ) {
        when (credential.method) {
            SshAuthMethod.PASSWORD -> {
                appModel.ssh.sshConnectRemoteServer(
                    serverId = server.id,
                    displayName = server.name,
                    host = server.hostname,
                    port = server.resolvedSshPort.toUShort(),
                    username = credential.username,
                    password = credential.password,
                    privateKeyPem = null,
                    passphrase = null,
                    acceptUnknownHost = true,
                    workingDir = null,
                    ipcSocketPathOverride = null,
                )
            }
            SshAuthMethod.KEY -> {
                appModel.ssh.sshConnectRemoteServer(
                    serverId = server.id,
                    displayName = server.name,
                    host = server.hostname,
                    port = server.resolvedSshPort.toUShort(),
                    username = credential.username,
                    password = null,
                    privateKeyPem = credential.privateKey,
                    passphrase = credential.passphrase,
                    acceptUnknownHost = true,
                    workingDir = null,
                    ipcSocketPathOverride = null,
                )
            }
        }
    }

    /**
     * Called when the app enters the foreground.
     */
    suspend fun onResume(context: Context, appModel: AppModel) {
        reconnectSavedServers(context, appModel)
        backgroundedTurnKeys.clear()
    }

    /**
     * Called when the app goes to background.
     * Tracks active turns for notification on completion.
     */
    fun onPause(appModel: AppModel) {
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
}
