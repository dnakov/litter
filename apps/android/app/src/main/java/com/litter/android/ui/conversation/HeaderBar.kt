package com.litter.android.ui.conversation

import android.content.Intent
import android.net.Uri
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.accentColor
import com.litter.android.state.AppThreadLaunchConfig
import com.litter.android.state.hasActiveTurn
import com.litter.android.state.isConnected
import com.litter.android.state.isIpcConnected
import com.litter.android.state.resolvedModel
import com.litter.android.state.statusColor
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ThreadKey

/**
 * Top bar showing model, reasoning, status dot, cwd.
 * Inline model selector expands on tap.
 */
@Composable
fun HeaderBar(
    thread: AppThreadSnapshot?,
    onBack: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    var showModelSelector by remember { mutableStateOf(false) }

    val server = remember(snapshot, thread) {
        thread?.let { t -> snapshot?.servers?.find { it.serverId == t.key.serverId } }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 8.dp, vertical = 6.dp),
        ) {
            IconButton(onClick = onBack, modifier = Modifier.size(32.dp)) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = LitterTheme.textPrimary,
                    modifier = Modifier.size(20.dp),
                )
            }

            // Status dot
            val health = server?.health ?: AppServerHealth.UNKNOWN
            val statusColor = server?.statusColor ?: health.accentColor
            val shouldPulse = health == AppServerHealth.CONNECTING || health == AppServerHealth.UNRESPONSIVE
            val dotAlpha = if (shouldPulse) {
                val infiniteTransition = rememberInfiniteTransition(label = "statusDotPulse")
                infiniteTransition.animateFloat(
                    initialValue = 0.3f,
                    targetValue = 1.0f,
                    animationSpec = infiniteRepeatable(
                        animation = tween(durationMillis = 1000),
                        repeatMode = RepeatMode.Reverse,
                    ),
                    label = "statusDotAlpha",
                ).value
            } else {
                1.0f
            }
            Box(
                modifier = Modifier
                    .size(8.dp)
                    .clip(CircleShape)
                    .background(statusColor.copy(alpha = dotAlpha)),
            )
            Spacer(Modifier.width(8.dp))

            // Model + reasoning label (tappable)
            Column(
                modifier = Modifier
                    .weight(1f)
                    .clickable { showModelSelector = !showModelSelector },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = thread?.resolvedModel ?: "",
                        color = LitterTheme.textPrimary,
                        fontSize = 13.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (HeaderOverrides.pendingFastMode) {
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "\u26A1",
                            color = LitterTheme.accent,
                            fontSize = 13.sp,
                        )
                    }
                }
                val cwd = thread?.info?.cwd
                if (cwd != null) {
                    val abbreviated = cwd.replace(Regex("^/home/[^/]+"), "~")
                        .replace(Regex("^/Users/[^/]+"), "~")
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text(
                            text = abbreviated,
                            color = LitterTheme.textMuted,
                            fontSize = 10.sp,
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f, fill = false),
                        )
                        if (server?.isIpcConnected == true) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "IPC",
                                color = LitterTheme.accentStrong,
                                fontSize = 10.sp,
                                modifier = Modifier
                                    .background(
                                        LitterTheme.accentStrong.copy(alpha = 0.14f),
                                        RoundedCornerShape(999.dp),
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
                    }
                }
            }

            // Reload button
            var isReloading by remember { mutableStateOf(false) }
            IconButton(
                onClick = {
                    if (thread == null || isReloading) return@IconButton
                    scope.launch {
                        isReloading = true
                        try {
                            if (server != null && !server.isLocal && server.account == null) {
                                val resp = appModel.rpc.loginAccount(
                                    thread.key.serverId,
                                    uniffi.codex_mobile_client.LoginAccountParams.Chatgpt,
                                )
                                if (resp is uniffi.codex_mobile_client.LoginAccountResponse.Chatgpt) {
                                    context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(resp.authUrl)))
                                }
                                return@launch
                            }
                            val config = AppThreadLaunchConfig(model = thread.model)
                            if (server?.isIpcConnected == true) {
                                try {
                                    appModel.externalResumeThread(thread.key)
                                } catch (_: Exception) {
                                    appModel.rpc.threadResume(
                                        thread.key.serverId,
                                        config.toThreadResumeParams(thread.key.threadId),
                                    )
                                }
                            } else {
                                appModel.rpc.threadResume(
                                    thread.key.serverId,
                                    config.toThreadResumeParams(thread.key.threadId),
                                )
                            }
                        } finally {
                            isReloading = false
                        }
                    }
                },
                enabled = !isReloading,
                modifier = Modifier.size(32.dp),
            ) {
                if (isReloading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp,
                        color = LitterTheme.accent,
                    )
                } else {
                    Icon(
                        Icons.Default.Refresh,
                        contentDescription = "Reload",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
        }

        // Inline model selector
        AnimatedVisibility(
            visible = showModelSelector,
            enter = expandVertically(),
            exit = shrinkVertically(),
        ) {
            ModelSelectorPanel(
                thread = thread,
                availableModels = server?.availableModels ?: emptyList(),
            )
        }
    }
}

/**
 * Holds pending model/effort/fast-mode overrides selected in the header.
 * Applied on the next [TurnStartParams] sent by the composer.
 */
object HeaderOverrides {
    var pendingModel: String? = null
    var pendingEffort: String? = null
    var pendingFastMode: Boolean = false
}

@Composable
private fun ModelSelectorPanel(
    thread: AppThreadSnapshot?,
    availableModels: List<uniffi.codex_mobile_client.Model>,
) {
    var selectedModel by remember { mutableStateOf(thread?.model) }
    var selectedEffort by remember { mutableStateOf(thread?.reasoningEffort) }
    var fastMode by remember { mutableStateOf(HeaderOverrides.pendingFastMode) }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.codeBackground)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            text = "Model",
            color = LitterTheme.textSecondary,
            fontSize = 11.sp,
        )

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(vertical = 4.dp),
        ) {
            items(availableModels) { model ->
                val isSelected = model.id == selectedModel
                FilterChip(
                    selected = isSelected,
                    onClick = {
                        selectedModel = model.id
                        HeaderOverrides.pendingModel = model.id
                    },
                    label = {
                        Text(
                            text = model.displayName ?: model.id,
                            fontSize = 11.sp,
                        )
                    },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
            }
        }

        // Reasoning effort chips
        val efforts = listOf("low", "medium", "high")
        Row(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Effort", color = LitterTheme.textSecondary, fontSize = 11.sp)
            Spacer(Modifier.width(4.dp))
            for (effort in efforts) {
                val isSelected = selectedEffort == effort
                FilterChip(
                    selected = isSelected,
                    onClick = {
                        selectedEffort = effort
                        HeaderOverrides.pendingEffort = effort
                    },
                    label = { Text(effort, fontSize = 10.sp) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
            }
        }

        // Fast mode toggle
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(top = 4.dp),
        ) {
            Text("Fast mode", color = LitterTheme.textSecondary, fontSize = 11.sp)
            Spacer(Modifier.weight(1f))
            Switch(
                checked = fastMode,
                onCheckedChange = {
                    fastMode = it
                    HeaderOverrides.pendingFastMode = it
                },
                colors = SwitchDefaults.colors(
                    checkedTrackColor = LitterTheme.accent,
                ),
            )
        }
    }
}
