package com.litter.android.ui.conversation

import android.net.Uri
import androidx.browser.customtabs.CustomTabsIntent
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
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.outlined.Info
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
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
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
    onInfo: (() -> Unit)? = null,
    showModelSelector: Boolean,
    onToggleModelSelector: () -> Unit,
    transparentBackground: Boolean = false,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val launchState by appModel.launchState.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val server = remember(snapshot, thread) {
        thread?.let { t -> snapshot?.servers?.find { it.serverId == t.key.serverId } }
    }
    val pendingModelId = launchState.selectedModel.trim()
    val pendingModelLabel = server?.availableModels
        ?.firstOrNull { it.id == pendingModelId }
        ?.displayName
        ?.ifBlank { pendingModelId }
        ?: pendingModelId.ifBlank { null }
    val currentModelId = pendingModelId.ifBlank {
        (thread?.model ?: thread?.info?.model ?: "").trim()
    }
    val selectedModelDefinition = remember(server?.availableModels, currentModelId) {
        server?.availableModels?.firstOrNull { it.id == currentModelId }
            ?: server?.availableModels?.firstOrNull { it.isDefault }
            ?: server?.availableModels?.firstOrNull()
    }
    val reasoningLabel = remember(launchState.reasoningEffort, thread?.reasoningEffort, selectedModelDefinition) {
        val pendingReasoning = launchState.reasoningEffort.trim()
        if (pendingReasoning.isNotEmpty()) {
            pendingReasoning
        } else {
            val threadReasoning = thread?.reasoningEffort?.trim().orEmpty()
            if (threadReasoning.isNotEmpty()) {
                threadReasoning
            } else {
                selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel) ?: "default"
            }
        }
    }
    val modelLabel = remember(pendingModelLabel, thread?.resolvedModel) {
        (pendingModelLabel ?: thread?.resolvedModel).orEmpty().ifBlank { "litter" }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .then(if (!transparentBackground) Modifier.background(LitterTheme.surface) else Modifier),
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
                    .clickable { onToggleModelSelector() },
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        text = modelLabel,
                        color = LitterTheme.textPrimary,
                        fontSize = 13.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    if (HeaderOverrides.pendingFastMode) {
                        Spacer(Modifier.width(4.dp))
                        Text(
                            text = "\u26A1",
                            color = LitterTheme.warning,
                            fontSize = 11.sp,
                        )
                    }
                    Spacer(Modifier.width(6.dp))
                    Text(
                        text = reasoningLabel,
                        color = LitterTheme.textSecondary,
                        fontSize = 12.sp,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis,
                    )
                    Spacer(Modifier.width(2.dp))
                    Icon(
                        Icons.Default.KeyboardArrowDown,
                        contentDescription = "Open model selector",
                        tint = LitterTheme.textSecondary,
                        modifier = Modifier.size(14.dp),
                    )
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
                                val authUrl = appModel.client.startRemoteSshOauthLogin(
                                    thread.key.serverId,
                                )
                                CustomTabsIntent.Builder()
                                    .setShowTitle(true)
                                    .build()
                                    .launchUrl(context, Uri.parse(authUrl))
                                return@launch
                            }
                            if (server?.isIpcConnected == true) {
                                try {
                                    appModel.externalResumeThread(thread.key)
                                } catch (_: Exception) {
                                    appModel.client.resumeThread(
                                        thread.key.serverId,
                                        appModel.launchState.threadResumeRequest(
                                            thread.key.threadId,
                                            cwdOverride = thread.info.cwd,
                                        ),
                                    )
                                }
                            } else {
                                appModel.client.resumeThread(
                                    thread.key.serverId,
                                    appModel.launchState.threadResumeRequest(
                                        thread.key.threadId,
                                        cwdOverride = thread.info.cwd,
                                    ),
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

            // Info button
            if (onInfo != null) {
                IconButton(
                    onClick = onInfo,
                    modifier = Modifier.size(32.dp),
                ) {
                    Icon(
                        Icons.Outlined.Info,
                        contentDescription = "Info",
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
 * Holds the fast-mode override selected in the header.
 * Launch model/effort state lives in [AppLaunchState].
 */
object HeaderOverrides {
    var pendingFastMode by mutableStateOf(false)
}

@Composable
private fun ModelSelectorPanel(
    thread: AppThreadSnapshot?,
    availableModels: List<uniffi.codex_mobile_client.ModelInfo>,
) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    val selectedModel = launchState.selectedModel
        .takeIf { it.isNotBlank() }
        ?: thread?.model
        ?: availableModels.firstOrNull { it.isDefault }?.id
        ?: availableModels.firstOrNull()?.id
    val fastMode = HeaderOverrides.pendingFastMode
    val selectedModelDefinition by remember(selectedModel, availableModels) {
        derivedStateOf {
            availableModels.firstOrNull { it.id == selectedModel }
                ?: availableModels.firstOrNull { it.isDefault }
                ?: availableModels.firstOrNull()
        }
    }
    val supportedEfforts = remember(selectedModelDefinition) {
        selectedModelDefinition?.supportedReasoningEfforts ?: emptyList()
    }
    val selectedEffort = launchState.reasoningEffort
        .takeIf { pending -> pending.isNotBlank() && supportedEfforts.any { effortLabel(it.reasoningEffort) == pending } }
        ?: thread?.reasoningEffort
            ?.takeIf { current -> supportedEfforts.any { effortLabel(it.reasoningEffort) == current } }
        ?: selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel)

    LaunchedEffect(launchState.reasoningEffort, selectedModelDefinition, supportedEfforts) {
        val pendingEffort = launchState.reasoningEffort.trim()
        val defaultEffort = selectedModelDefinition?.defaultReasoningEffort
        if (pendingEffort.isEmpty() || defaultEffort == null || supportedEfforts.isEmpty()) {
            return@LaunchedEffect
        }
        if (supportedEfforts.none { effortLabel(it.reasoningEffort) == pendingEffort }) {
            appModel.launchState.updateReasoningEffort(
                effortLabel(defaultEffort),
            )
        }
    }

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
                        appModel.launchState.updateSelectedModel(model.id)
                        appModel.launchState.updateReasoningEffort(
                            model.defaultReasoningEffort.let(::effortLabel),
                        )
                    },
                    label = {
                        Text(
                            text = model.displayName.ifBlank { model.id },
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

        if (availableModels.isEmpty()) {
            Text(
                text = "Loading models…",
                color = LitterTheme.textMuted,
                fontSize = 11.sp,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text("Effort", color = LitterTheme.textSecondary, fontSize = 11.sp)
                Spacer(Modifier.width(4.dp))
            }
            LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                items(supportedEfforts) { option ->
                    val effort = effortLabel(option.reasoningEffort)
                    FilterChip(
                        selected = selectedEffort == effort,
                        onClick = {
                            appModel.launchState.updateReasoningEffort(effort)
                        },
                        label = { Text(effort, fontSize = 10.sp) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent,
                            selectedLabelColor = Color.Black,
                        ),
                    )
                }
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
                    HeaderOverrides.pendingFastMode = it
                },
                colors = SwitchDefaults.colors(
                    checkedTrackColor = LitterTheme.accent,
                ),
            )
        }
    }
}

private fun effortLabel(value: uniffi.codex_mobile_client.ReasoningEffort): String =
    when (value) {
        uniffi.codex_mobile_client.ReasoningEffort.NONE -> "none"
        uniffi.codex_mobile_client.ReasoningEffort.MINIMAL -> "minimal"
        uniffi.codex_mobile_client.ReasoningEffort.LOW -> "low"
        uniffi.codex_mobile_client.ReasoningEffort.MEDIUM -> "medium"
        uniffi.codex_mobile_client.ReasoningEffort.HIGH -> "high"
        uniffi.codex_mobile_client.ReasoningEffort.X_HIGH -> "xhigh"
    }
