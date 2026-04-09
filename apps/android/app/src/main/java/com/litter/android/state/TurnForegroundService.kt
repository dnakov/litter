package com.litter.android.state

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import com.litter.android.util.LLog
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Foreground service that keeps the process alive while turns are active.
 * Replaces iOS Live Activities / background tasks.
 */
class TurnForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "active_turns"
        private const val NOTIFICATION_ID = 9002

        fun start(context: Context) {
            val intent = Intent(context, TurnForegroundService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, TurnForegroundService::class.java))
        }
    }

    private val lifecycleController = AppLifecycleController()
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var monitorJob: Job? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        startForeground(NOTIFICATION_ID, buildNotification("Codex is working\u2026"))

        val appModel = runCatching {
            AppModel.init(applicationContext).also { it.start() }
        }.getOrElse { error ->
            LLog.e("TurnForegroundService", "Failed to initialize AppModel", error)
            stopSelf()
            return START_NOT_STICKY
        }

        monitorJob?.cancel()
        monitorJob = scope.launch {
            lifecycleController.onBackgroundServiceStart(this@TurnForegroundService, appModel)
            while (true) {
                delay(2000)
                val snap = appModel.snapshot.value
                val activeCount = snap?.threads?.count { it.activeTurnId != null } ?: 0

                if (activeCount == 0) {
                    stopSelf()
                    return@launch
                }

                val notification = buildNotification(
                    "$activeCount active turn${if (activeCount > 1) "s" else ""}",
                )
                val nm = getSystemService(NotificationManager::class.java)
                nm.notify(NOTIFICATION_ID, notification)
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        monitorJob?.cancel()
        super.onDestroy()
    }

    private fun buildNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle("Codex")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Active Turns",
                NotificationManager.IMPORTANCE_LOW,
            )
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
}
