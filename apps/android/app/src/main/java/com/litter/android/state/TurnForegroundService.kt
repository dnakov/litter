package com.litter.android.state

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder
import android.os.SystemClock
import android.widget.RemoteViews
import androidx.core.app.NotificationCompat
import com.litter.android.MainActivity
import com.litter.android.util.LLog
import com.sigkitten.litter.android.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import com.litter.android.ui.widget.ActiveTurnWidget
import uniffi.codex_mobile_client.AppInterruptTurnRequest
import uniffi.codex_mobile_client.AppSnapshotRecord
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.HydratedConversationItemContent

/**
 * Foreground service that keeps the process alive while turns are active.
 * Shows a rich notification with phase, model, elapsed time, tool count,
 * context usage, output snippet, and a cancel action.
 */
class TurnForegroundService : Service() {

    companion object {
        private const val CHANNEL_ID = "active_turns"
        private const val NOTIFICATION_ID = 9002
        private const val ACTION_CANCEL_TURN = "com.litter.android.CANCEL_TURN"
        private const val EXTRA_SERVER_ID = "server_id"
        private const val EXTRA_THREAD_ID = "thread_id"
        private const val EXTRA_TURN_ID = "turn_id"

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
    private var turnStartElapsedRealtime: Long = 0L
    private var trackedThreadKey: uniffi.codex_mobile_client.ThreadKey? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_CANCEL_TURN) {
            handleCancelTurn(intent)
            return START_NOT_STICKY
        }

        startForeground(NOTIFICATION_ID, buildFallbackNotification("Codex is working\u2026"))

        val appModel = runCatching {
            AppModel.init(applicationContext).also { it.start() }
        }.getOrElse { error ->
            LLog.e("TurnForegroundService", "Failed to initialize AppModel", error)
            stopSelf()
            return START_NOT_STICKY
        }

        monitorJob?.cancel()
        turnStartElapsedRealtime = SystemClock.elapsedRealtime()
        trackedThreadKey = null
        monitorJob = scope.launch {
            lifecycleController.onBackgroundServiceStart(this@TurnForegroundService, appModel)
            while (true) {
                delay(2000)
                val snap = appModel.snapshot.value
                val activeThreads = snap?.threads?.filter { it.hasActiveTurn } ?: emptyList()

                if (activeThreads.isEmpty()) {
                    // Show completed state briefly before stopping
                    val nm = getSystemService(NotificationManager::class.java)
                    nm.notify(NOTIFICATION_ID, buildCompletedNotification(snap))
                    runCatching { ActiveTurnWidget.triggerUpdate(applicationContext) }
                    delay(3000)
                    stopSelf()
                    return@launch
                }

                // Pick best thread: prefer active thread, else first active
                val best = activeThreads.firstOrNull { it.key == snap?.activeThread }
                    ?: activeThreads.first()

                // Reset timer if we started tracking a new thread
                if (trackedThreadKey != best.key) {
                    trackedThreadKey = best.key
                    turnStartElapsedRealtime = SystemClock.elapsedRealtime()
                }

                val notification = buildRichNotification(best, activeThreads.size, snap!!)
                val nm = getSystemService(NotificationManager::class.java)
                nm.notify(NOTIFICATION_ID, notification)

                // Update home screen widget
                runCatching { ActiveTurnWidget.triggerUpdate(applicationContext) }
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        monitorJob?.cancel()
        super.onDestroy()
    }

    private fun handleCancelTurn(intent: Intent) {
        val serverId = intent.getStringExtra(EXTRA_SERVER_ID) ?: return
        val threadId = intent.getStringExtra(EXTRA_THREAD_ID) ?: return
        val turnId = intent.getStringExtra(EXTRA_TURN_ID) ?: return
        scope.launch {
            try {
                val appModel = AppModel.init(applicationContext)
                appModel.client.interruptTurn(
                    serverId,
                    AppInterruptTurnRequest(threadId = threadId, turnId = turnId),
                )
            } catch (e: Exception) {
                LLog.e("TurnForegroundService", "Failed to cancel turn", e)
            }
        }
    }

    private fun buildRichNotification(
        thread: AppThreadSnapshot,
        activeCount: Int,
        snapshot: AppSnapshotRecord,
    ): Notification {
        val phase = resolvePhase(thread)
        val model = thread.resolvedModel
        val contextPct = thread.contextPercent
        val toolCount = countToolCalls(thread)
        val snippet = thread.latestAssistantSnippet
        val prompt = thread.resolvedPreview

        val remoteViews = RemoteViews(packageName, R.layout.notification_turn_progress)

        // Phase badge
        remoteViews.setTextViewText(R.id.phase_badge, phase.label)
        remoteViews.setTextColor(R.id.phase_badge, phase.color)

        // Model name
        remoteViews.setTextViewText(R.id.model_name, model.ifEmpty { "unknown" })

        // Elapsed time
        remoteViews.setViewVisibility(R.id.elapsed_timer, android.view.View.GONE)
        val elapsedMs = SystemClock.elapsedRealtime() - turnStartElapsedRealtime
        val elapsedSec = (elapsedMs / 1000).toInt()
        val minutes = elapsedSec / 60
        val seconds = elapsedSec % 60
        remoteViews.setTextViewText(R.id.elapsed_text, String.format("%d:%02d", minutes, seconds))

        // Output snippet
        val displayText = when {
            !snippet.isNullOrBlank() -> snippet
            phase == TurnPhase.THINKING -> "Thinking\u2026"
            phase == TurnPhase.TOOL_CALL -> "Running tool\u2026"
            else -> "Working\u2026"
        }
        remoteViews.setTextViewText(R.id.output_snippet, displayText)

        // Tool count
        if (toolCount > 0) {
            remoteViews.setViewVisibility(R.id.tool_count, android.view.View.VISIBLE)
            remoteViews.setTextViewText(R.id.tool_count, "\u2329/\u232A $toolCount tools")
        } else {
            remoteViews.setViewVisibility(R.id.tool_count, android.view.View.GONE)
        }

        // Context percent
        if (contextPct > 0) {
            remoteViews.setViewVisibility(R.id.context_percent, android.view.View.VISIBLE)
            remoteViews.setTextViewText(R.id.context_percent, "ctx $contextPct%")
            val ctxColor = when {
                contextPct >= 80 -> 0xFFFF6B6B.toInt()
                contextPct >= 60 -> 0xFFFF9500.toInt()
                else -> 0xFF8E8E93.toInt()
            }
            remoteViews.setTextColor(R.id.context_percent, ctxColor)
        } else {
            remoteViews.setViewVisibility(R.id.context_percent, android.view.View.GONE)
        }

        val contentIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle(buildContentTitle(activeCount, prompt))
            .setStyle(NotificationCompat.DecoratedCustomViewStyle())
            .setCustomContentView(remoteViews)
            .setOngoing(true)
            .setSilent(true)
            .setContentIntent(contentIntent)
            .setWhen(System.currentTimeMillis() - elapsedMs)
            .setUsesChronometer(true)

        // Cancel turn action
        val turnId = thread.activeTurnId
        if (turnId != null) {
            val cancelIntent = Intent(this, TurnForegroundService::class.java).apply {
                action = ACTION_CANCEL_TURN
                putExtra(EXTRA_SERVER_ID, thread.key.serverId)
                putExtra(EXTRA_THREAD_ID, thread.key.threadId)
                putExtra(EXTRA_TURN_ID, turnId)
            }
            val cancelPending = PendingIntent.getService(
                this,
                1,
                cancelIntent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
            )
            builder.addAction(0, "Cancel Turn", cancelPending)
        }

        return builder.build()
    }

    private fun buildCompletedNotification(snapshot: AppSnapshotRecord?): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle("Codex")
            .setContentText("Turn completed")
            .setOngoing(false)
            .setSilent(true)
            .build()
    }

    private fun buildFallbackNotification(text: String): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_popup_sync)
            .setContentTitle("Codex")
            .setContentText(text)
            .setOngoing(true)
            .setSilent(true)
            .build()
    }

    private fun buildContentTitle(activeCount: Int, prompt: String): String {
        val prefix = if (activeCount > 1) "[$activeCount] " else ""
        val truncated = if (prompt.length > 60) prompt.take(57) + "\u2026" else prompt
        return "${prefix}${truncated}"
    }

    private fun countToolCalls(thread: AppThreadSnapshot): Int {
        return thread.hydratedConversationItems.count { item ->
            when (item.content) {
                is HydratedConversationItemContent.CommandExecution,
                is HydratedConversationItemContent.McpToolCall,
                is HydratedConversationItemContent.DynamicToolCall,
                is HydratedConversationItemContent.FileChange,
                is HydratedConversationItemContent.WebSearch,
                -> true
                else -> false
            }
        }
    }

    private fun resolvePhase(thread: AppThreadSnapshot): TurnPhase {
        val items = thread.hydratedConversationItems
        if (items.isEmpty()) return TurnPhase.THINKING

        // Check last few items for tool execution
        for (i in items.indices.reversed()) {
            val content = items[i].content
            return when (content) {
                is HydratedConversationItemContent.CommandExecution -> TurnPhase.TOOL_CALL
                is HydratedConversationItemContent.McpToolCall -> TurnPhase.TOOL_CALL
                is HydratedConversationItemContent.DynamicToolCall -> TurnPhase.TOOL_CALL
                is HydratedConversationItemContent.WebSearch -> TurnPhase.TOOL_CALL
                is HydratedConversationItemContent.Assistant -> TurnPhase.THINKING
                is HydratedConversationItemContent.Reasoning -> TurnPhase.THINKING
                else -> continue
            }
        }
        return TurnPhase.THINKING
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

    private enum class TurnPhase(val label: String, val color: Int) {
        THINKING("thinking", 0xFFFF9500.toInt()),
        TOOL_CALL("running tool", 0xFFFF9500.toInt()),
        COMPLETED("completed", 0xFF8E8E93.toInt()),
        FAILED("failed", 0xFFFF6B6B.toInt()),
    }
}
