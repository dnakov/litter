package com.litter.android

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.core.view.WindowCompat
import com.litter.android.state.ServerManager
import com.litter.android.ui.LitterAppShell
import com.litter.android.ui.LitterAppTheme
import com.litter.android.ui.rememberLitterAppState

class MainActivity : ComponentActivity() {
    private lateinit var serverManager: ServerManager

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)
        // disable system window fitting so compose can handle keyboard padding natively
        WindowCompat.setDecorFitsSystemWindows(window, false)

        serverManager = ServerManager(context = this)

        setContent {
            LitterAppTheme {
                val appState = rememberLitterAppState(serverManager = serverManager)
                LitterAppShell(appState = appState)
            }
        }
    }

    override fun onDestroy() {
        if (::serverManager.isInitialized) {
            serverManager.close()
        }
        super.onDestroy()
    }
}
