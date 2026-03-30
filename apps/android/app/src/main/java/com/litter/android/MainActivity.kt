package com.litter.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.core.view.WindowCompat
import androidx.lifecycle.lifecycleScope
import com.litter.android.state.AppLifecycleController
import com.litter.android.state.AppModel
import com.litter.android.state.OpenAIApiKeyStore
import com.litter.android.state.TurnForegroundService
import com.litter.android.ui.AnimatedSplashScreen
import com.litter.android.ui.ExperimentalFeatures
import com.litter.android.ui.LitterApp
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.WallpaperManager
import com.litter.android.util.LLog
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class MainActivity : ComponentActivity() {
    private lateinit var appModel: AppModel
    private val lifecycleController = AppLifecycleController()

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        OpenAIApiKeyStore(applicationContext).applyToEnvironment()
        ExperimentalFeatures.initialize(applicationContext)

        try {
            appModel = AppModel.init(this)
            WallpaperManager.initialize(this)
            appModel.start()
        } catch (e: Exception) {
            LLog.e("MainActivity", "AppModel.start() failed", e)
        }

        var showSplash by mutableStateOf(true)
        var contentReady by mutableStateOf(false)
        var minTimeElapsed by mutableStateOf(false)

        setContent {
            LitterAppTheme {
                Box(Modifier.fillMaxSize()) {
                    LitterApp(appModel = appModel)

                    // Signal content ready when LitterApp composes
                    LaunchedEffect(Unit) { contentReady = true }

                    // Minimum display time
                    LaunchedEffect(Unit) {
                        delay(800)
                        minTimeElapsed = true
                    }

                    // Dismiss when both ready and min time elapsed (or hard max 3s)
                    LaunchedEffect(contentReady, minTimeElapsed) {
                        if (contentReady && minTimeElapsed) showSplash = false
                    }
                    LaunchedEffect(Unit) {
                        delay(3000)
                        showSplash = false
                    }

                    AnimatedVisibility(
                        visible = showSplash,
                        exit = fadeOut(),
                    ) {
                        AnimatedSplashScreen()
                    }
                }
            }
        }

        lifecycleScope.launch {
            // Connect local in-process server (same as iOS — no separate process)
            connectLocalServer()
        }
    }

    override fun onResume() {
        super.onResume()
        TurnForegroundService.stop(this)
        lifecycleScope.launch {
            lifecycleController.onResume(this@MainActivity, appModel)
        }
    }

    override fun onPause() {
        super.onPause()
        lifecycleController.onPause(appModel)
        if (lifecycleController.getBackgroundedTurnKeys().isNotEmpty()) {
            TurnForegroundService.start(this)
        }
    }

    override fun onDestroy() {
        appModel.stop()
        super.onDestroy()
    }

    /**
     * Start the Codex server in-process via Rust (same as iOS).
     * No separate binary, no WebSocket — uses internal async channels.
     */
    private suspend fun connectLocalServer() {
        try {
            appModel.serverBridge.connectLocalServer(
                serverId = "local",
                displayName = "This Device",
                host = "127.0.0.1",
                port = 0u, // port 0 = in-process, Rust handles it
            )
            appModel.restoreStoredLocalChatGptAuth("local")
            // Load thread list for the local server
            appModel.client.listThreads(
                "local",
                uniffi.codex_mobile_client.AppListThreadsRequest(
                    cursor = null,
                    limit = null,
                    archived = false,
                    cwd = null,
                    searchTerm = null,
                ),
            )
            LLog.i("MainActivity", "Local in-process server connected")
        } catch (e: Exception) {
            LLog.w("MainActivity", "Local server failed", fields = mapOf("error" to e.message))
        }
    }
}
