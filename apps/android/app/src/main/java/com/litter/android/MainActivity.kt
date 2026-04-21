package com.litter.android

import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Text
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
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
import uniffi.codex_mobile_client.ThreadKey

class MainActivity : ComponentActivity() {
    companion object {
        const val EXTRA_NOTIFICATION_SERVER_ID = "litter.notification.serverId"
        const val EXTRA_NOTIFICATION_THREAD_ID = "litter.notification.threadId"
    }

    private var appModel: AppModel? = null
    private val lifecycleController = AppLifecycleController()

    override fun onCreate(savedInstanceState: Bundle?) {
        // Must be called before super.onCreate to hand off the system splash
        // (Theme.App.Starting) to the Compose AnimatedSplashScreen without a
        // theme-background flash between them.
        installSplashScreen()
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        OpenAIApiKeyStore(applicationContext).applyToEnvironment()
        ExperimentalFeatures.initialize(applicationContext)

        try {
            appModel = AppModel.init(this)
            WallpaperManager.initialize(this)
            appModel?.start()
        } catch (e: Exception) {
            LLog.e("MainActivity", "AppModel.start() failed", e)
        }

        var showSplash by mutableStateOf(true)
        var contentReady by mutableStateOf(false)
        var minTimeElapsed by mutableStateOf(false)

        setContent {
            LitterAppTheme {
                Box(Modifier.fillMaxSize()) {
                    val model = appModel
                    if (model != null) {
                        LitterApp(appModel = model)
                    } else {
                        Text(
                            text = "Litter couldn't finish starting.",
                            modifier = Modifier.padding(horizontal = 24.dp),
                        )
                    }

                    // Signal content ready when LitterApp composes
                    LaunchedEffect(model) {
                        if (model != null) {
                            contentReady = true
                        }
                    }

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

        handleNotificationIntent(intent)
    }

    override fun onResume() {
        super.onResume()
        TurnForegroundService.stop(this)
        val model = appModel ?: return
        lifecycleScope.launch {
            lifecycleController.onResume(this@MainActivity, model)
        }
    }

    override fun onPause() {
        super.onPause()
        val model = appModel ?: return
        lifecycleController.onPause(model)
        if (lifecycleController.getBackgroundedTurnKeys().isNotEmpty()) {
            TurnForegroundService.start(this)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        handleNotificationIntent(intent)
    }

    override fun onDestroy() {
        appModel?.stop()
        super.onDestroy()
    }

    private fun handleNotificationIntent(intent: Intent?) {
        val threadKey = consumeNotificationThreadKey(intent) ?: return
        val model = appModel ?: return
        lifecycleScope.launch {
            model.activateThread(threadKey)
            model.refreshSnapshot()

            val resolvedKey = model.ensureThreadLoaded(threadKey) ?: threadKey
            model.activateThread(resolvedKey)
            model.refreshSnapshot()
        }
    }

    private fun consumeNotificationThreadKey(intent: Intent?): ThreadKey? {
        intent ?: return null
        val serverId = intent.getStringExtra(EXTRA_NOTIFICATION_SERVER_ID)?.trim().orEmpty()
        val threadId = intent.getStringExtra(EXTRA_NOTIFICATION_THREAD_ID)?.trim().orEmpty()
        if (serverId.isEmpty() || threadId.isEmpty()) {
            return null
        }

        intent.removeExtra(EXTRA_NOTIFICATION_SERVER_ID)
        intent.removeExtra(EXTRA_NOTIFICATION_THREAD_ID)
        return ThreadKey(serverId = serverId, threadId = threadId)
    }
}
