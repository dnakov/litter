package com.litter.android.state

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import android.content.pm.PackageManager

internal class AwayNotificationHelper(
    private val context: Context,
) {
    private val prefs = context.getSharedPreferences(PREFERENCES_NAME, Context.MODE_PRIVATE)

    init {
        ensureChannels()
    }

    fun notify(
        dedupeKey: String,
        title: String,
        body: String,
    ) {
        pruneLedger()
        if (prefs.contains(dedupeKey)) {
            return
        }
        prefs.edit().putLong(dedupeKey, System.currentTimeMillis()).apply()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val granted =
                ContextCompat.checkSelfPermission(
                    context,
                    Manifest.permission.POST_NOTIFICATIONS,
                ) == PackageManager.PERMISSION_GRANTED
            if (!granted) {
                return
            }
        }

        val channelId = if (dedupeKey.startsWith("error") || dedupeKey.startsWith("approval")) CHANNEL_ALERTS else CHANNEL_MESSAGES
        val notification =
            NotificationCompat.Builder(context, channelId)
                .setSmallIcon(android.R.drawable.stat_notify_chat)
                .setContentTitle(title)
                .setContentText(body)
                .setStyle(NotificationCompat.BigTextStyle().bigText(body))
                .setPriority(NotificationCompat.PRIORITY_HIGH)
                .setAutoCancel(true)
                .build()

        NotificationManagerCompat.from(context).notify(dedupeKey.hashCode(), notification)
    }

    private fun ensureChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            return
        }
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channels =
            listOf(
                NotificationChannel(
                    CHANNEL_MESSAGES,
                    "Thread Updates",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Assistant replies from background websocket events"
                },
                NotificationChannel(
                    CHANNEL_ALERTS,
                    "Alerts",
                    NotificationManager.IMPORTANCE_HIGH,
                ).apply {
                    description = "Errors and approval requests"
                },
            )
        manager.createNotificationChannels(channels)
    }

    private fun pruneLedger() {
        val now = System.currentTimeMillis()
        val cutoff = now - LEDGER_RETENTION_MS
        val snapshot = prefs.all
        if (snapshot.isEmpty()) {
            return
        }
        val editor = prefs.edit()
        var changed = false
        for ((key, value) in snapshot) {
            val timestamp = (value as? Long) ?: continue
            if (timestamp < cutoff) {
                editor.remove(key)
                changed = true
            }
        }
        if (changed) {
            editor.apply()
        }
    }

    private companion object {
        private const val CHANNEL_MESSAGES = "litter_messages"
        private const val CHANNEL_ALERTS = "litter_alerts"
        private const val PREFERENCES_NAME = "litter_notification_ledger"
        private const val LEDGER_RETENTION_MS = 24L * 60L * 60L * 1000L
    }
}
