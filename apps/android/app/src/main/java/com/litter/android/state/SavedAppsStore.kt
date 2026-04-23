package com.litter.android.state

import android.content.Context
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import uniffi.codex_mobile_client.SavedApp
import uniffi.codex_mobile_client.SavedAppException
import uniffi.codex_mobile_client.SavedAppState
import uniffi.codex_mobile_client.SavedAppUpdateResult
import uniffi.codex_mobile_client.SavedAppWithPayload
import uniffi.codex_mobile_client.savedAppDelete
import uniffi.codex_mobile_client.savedAppGet
import uniffi.codex_mobile_client.savedAppLoadState
import uniffi.codex_mobile_client.savedAppPromote
import uniffi.codex_mobile_client.savedAppRename
import uniffi.codex_mobile_client.savedAppReplaceHtml
import uniffi.codex_mobile_client.savedAppSaveState
import uniffi.codex_mobile_client.savedAppsForThread
import uniffi.codex_mobile_client.savedAppsList

/**
 * Thin Kotlin wrapper around the Rust `saved_app_*` persistence surfaces and
 * [AppClient.updateSavedApp]. Rust owns the storage format, JSON cap, atomic
 * writes, and the update orchestration; this object only fronts them with a
 * reactive [StateFlow] and a per-id debouncer so a dragging slider inside a
 * WebView does not spam disk writes.
 */
object SavedAppsStore {
    private const val TAG = "SavedAppsStore"
    private const val SAVE_STATE_DEBOUNCE_MS = 250L

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val mutex = Mutex()
    private val debouncers = mutableMapOf<String, DebouncedSave>()

    private val _apps = MutableStateFlow<List<SavedApp>>(emptyList())
    val apps: StateFlow<List<SavedApp>> = _apps.asStateFlow()

    private data class DebouncedSave(
        var job: Job,
        var pendingStateJson: String,
        var pendingSchemaVersion: UInt,
    )

    suspend fun reload(context: Context) {
        val snapshot = withContext(Dispatchers.IO) {
            savedAppsList(SavedAppsDirectory.path(context))
        }
        _apps.value = snapshot.apps
    }

    suspend fun promote(
        context: Context,
        title: String,
        widgetHtml: String,
        width: Double,
        height: Double,
        originThreadId: String?,
    ): SavedApp {
        val app = withContext(Dispatchers.IO) {
            savedAppPromote(
                SavedAppsDirectory.path(context),
                title,
                widgetHtml,
                width,
                height,
                originThreadId,
            )
        }
        reload(context)
        return app
    }

    suspend fun rename(context: Context, appId: String, title: String): SavedApp {
        val app = withContext(Dispatchers.IO) {
            savedAppRename(SavedAppsDirectory.path(context), appId, title)
        }
        reload(context)
        return app
    }

    suspend fun delete(context: Context, appId: String) {
        withContext(Dispatchers.IO) {
            savedAppDelete(SavedAppsDirectory.path(context), appId)
        }
        cancelPendingSave(appId)
        reload(context)
    }

    suspend fun getWithPayload(context: Context, appId: String): SavedAppWithPayload? =
        withContext(Dispatchers.IO) {
            savedAppGet(SavedAppsDirectory.path(context), appId)
        }

    suspend fun loadState(context: Context, appId: String): SavedAppState? =
        withContext(Dispatchers.IO) {
            savedAppLoadState(SavedAppsDirectory.path(context), appId)
        }

    /**
     * Apps whose `origin_thread_id` matches [threadId], newest-updated first.
     * Used by the home-screen app-row takeover.
     */
    suspend fun appsForThread(context: Context, threadId: String): List<SavedApp> =
        withContext(Dispatchers.IO) {
            savedAppsForThread(SavedAppsDirectory.path(context), threadId)
        }

    /**
     * Resolve a saved app by its model-chosen slug ([SavedApp.appId]) within a
     * specific thread. Slugs are unique only within a thread — the same slug
     * in two threads is two independent apps.
     */
    suspend fun appForSlug(context: Context, slug: String, threadId: String): SavedApp? =
        appsForThread(context, threadId).firstOrNull { it.appId == slug }

    /**
     * Trailing-edge debounced save keyed by [appId]. A burst of rapid writes
     * from the WebView (slider drag, typing) coalesces into one disk write
     * [SAVE_STATE_DEBOUNCE_MS] after the last call.
     *
     * [SavedAppException.StateTooLarge] and other Rust-side validation errors
     * are logged and swallowed: the widget keeps working, the oversized save
     * is simply not persisted.
     */
    fun saveState(
        context: Context,
        appId: String,
        stateJson: String,
        schemaVersion: UInt,
    ) {
        val appContext = context.applicationContext
        scope.launch {
            mutex.withLock {
                val existing = debouncers[appId]
                if (existing != null) {
                    existing.pendingStateJson = stateJson
                    existing.pendingSchemaVersion = schemaVersion
                    existing.job.cancel()
                }
                val job = scope.launch {
                    delay(SAVE_STATE_DEBOUNCE_MS)
                    val (jsonToWrite, schema) = mutex.withLock {
                        val pending = debouncers.remove(appId) ?: return@withLock null
                        pending.pendingStateJson to pending.pendingSchemaVersion
                    } ?: return@launch
                    try {
                        savedAppSaveState(
                            MobilePreferencesDirectory.path(appContext),
                            appId,
                            jsonToWrite,
                            schema,
                        )
                    } catch (e: SavedAppException.StateTooLarge) {
                        Log.w(TAG, "saveState rejected (too large) appId=$appId", e)
                    } catch (e: SavedAppException) {
                        Log.w(TAG, "saveState failed appId=$appId", e)
                    } catch (e: Exception) {
                        Log.e(TAG, "saveState unexpected failure appId=$appId", e)
                    }
                }
                debouncers[appId] = DebouncedSave(job, stateJson, schemaVersion)
            }
        }
    }

    /**
     * Flush any pending debounced save for [appId] synchronously. Call this
     * from the detail view's onDispose so a quick tap-and-leave still
     * persists.
     */
    suspend fun flushPendingSave(context: Context, appId: String) {
        val pending = mutex.withLock {
            val existing = debouncers.remove(appId) ?: return@withLock null
            existing.job.cancel()
            existing.pendingStateJson to existing.pendingSchemaVersion
        } ?: return
        val (stateJson, schemaVersion) = pending
        try {
            withContext(Dispatchers.IO) {
                savedAppSaveState(
                    SavedAppsDirectory.path(context),
                    appId,
                    stateJson,
                    schemaVersion,
                )
            }
        } catch (e: Exception) {
            Log.w(TAG, "flushPendingSave failed appId=$appId", e)
        }
    }

    private suspend fun cancelPendingSave(appId: String) {
        mutex.withLock {
            debouncers.remove(appId)?.job?.cancel()
        }
    }

    suspend fun requestUpdate(
        context: Context,
        serverId: String,
        appId: String,
        prompt: String,
    ): SavedApp {
        val appModel = AppModel.shared
        val result = appModel.client.updateSavedApp(
            serverId,
            SavedAppsDirectory.path(context),
            appId,
            prompt,
        )
        return when (result) {
            is SavedAppUpdateResult.Success -> {
                reload(context)
                result.app
            }

            is SavedAppUpdateResult.Error ->
                throw IllegalStateException(result.message)
        }
    }

    /**
     * Direct HTML replacement escape hatch for tests or future bulk-import
     * flows. The normal update path is [requestUpdate].
     */
    suspend fun replaceHtml(
        context: Context,
        appId: String,
        widgetHtml: String,
        width: Double,
        height: Double,
    ): SavedApp {
        val app = withContext(Dispatchers.IO) {
            savedAppReplaceHtml(
                SavedAppsDirectory.path(context),
                appId,
                widgetHtml,
                width,
                height,
            )
        }
        reload(context)
        return app
    }
}
