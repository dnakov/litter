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
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
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
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
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
import com.litter.android.state.ServerModelPreferenceStore
import com.litter.android.state.statusColor
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppServerHealth
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ThreadKey

/**
 * Top bar showing model, reasoning, status dot, cwd.
 * Inline model selector expands on tap.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HeaderBar(
    thread: AppThreadSnapshot?,
    onBack: () -> Unit,
    onInfo: (() -> Unit)? = null,
    showModelSelector: Boolean,
    onToggleModelSelector: () -> Unit,
    onReloadError: ((String) -> Unit)? = null,
    transparentBackground: Boolean = false,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val snapshot by appModel.snapshot.collectAsState()
    val launchState by appModel.launchState.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    var showModelBrowser by remember(thread?.key) { mutableStateOf(false) }
    val server = remember(snapshot, thread) {
        thread?.let { t -> snapshot?.servers?.find { it.serverId == t.key.serverId } }
    }
    val currentServerId = thread?.key?.serverId
    val pendingModelId = appModel.launchState.selectedModel(currentServerId).trim()
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
    val reasoningLabel = remember(appModel.launchState.selectedReasoningEffort(currentServerId), thread?.reasoningEffort, selectedModelDefinition) {
        val pendingReasoning = appModel.launchState.selectedReasoningEffort(currentServerId).trim()
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
    val providerLabel = remember(pendingModelId, thread?.info?.modelProvider, thread?.resolvedModel) {
        val threadProvider = thread?.info?.modelProvider?.trim().orEmpty()
        headerModelProviderLabel(pendingModelId)
            ?: threadProvider.takeIf { it.isNotEmpty() }
            ?: headerModelProviderLabel(thread?.resolvedModel.orEmpty())
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
                    providerLabel?.let { provider ->
                        Spacer(Modifier.width(6.dp))
                        Text(
                            text = provider,
                            color = Color.Black,
                            fontSize = 10.sp,
                            modifier = Modifier
                                .background(LitterTheme.accent, RoundedCornerShape(999.dp))
                                .padding(horizontal = 6.dp, vertical = 2.dp),
                        )
                    }
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
                        if (thread?.collaborationMode == AppModeKind.PLAN) {
                            Spacer(Modifier.width(6.dp))
                            Text(
                                text = "plan",
                                color = Color.Black,
                                fontSize = 10.sp,
                                fontWeight = androidx.compose.ui.text.font.FontWeight.Bold,
                                modifier = Modifier
                                    .background(
                                        LitterTheme.accent,
                                        RoundedCornerShape(999.dp),
                                    )
                                    .padding(horizontal = 6.dp, vertical = 2.dp),
                            )
                        }
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
                                            threadKey = thread.key,
                                        ),
                                    )
                                }
                            } else {
                                appModel.client.resumeThread(
                                    thread.key.serverId,
                                    appModel.launchState.threadResumeRequest(
                                        thread.key.threadId,
                                        cwdOverride = thread.info.cwd,
                                        threadKey = thread.key,
                                    ),
                                )
                            }
                            appModel.refreshSnapshot()
                        } catch (e: Exception) {
                            onReloadError?.invoke(e.message ?: "Failed to reload conversation")
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
                onBrowseAllModels = { showModelBrowser = true },
                onToggleMode = { mode ->
                    thread?.let { t ->
                        scope.launch {
                            try {
                                appModel.store.setThreadCollaborationMode(t.key, mode)
                            } catch (_: Exception) {}
                        }
                    }
                },
            )
        }
    }

    if (showModelBrowser) {
        ModalBottomSheet(
            onDismissRequest = { showModelBrowser = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.surface,
        ) {
            ModelBrowserSheet(
                thread = thread,
                server = server,
                availableModels = server?.availableModels ?: emptyList(),
                onDismiss = { showModelBrowser = false },
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
    onBrowseAllModels: (() -> Unit)? = null,
    onToggleMode: ((AppModeKind) -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val snapshot by appModel.snapshot.collectAsState()
    val launchState by appModel.launchState.snapshot.collectAsState()
    val serverId = thread?.key?.serverId
    val selectedModel = appModel.launchState.selectedModel(serverId)
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
    val selectedEffort = appModel.launchState.selectedReasoningEffort(serverId)
        .takeIf { pending -> pending.isNotBlank() && supportedEfforts.any { effortLabel(it.reasoningEffort) == pending } }
        ?: thread?.reasoningEffort
            ?.takeIf { current -> supportedEfforts.any { effortLabel(it.reasoningEffort) == current } }
        ?: selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel)
    val quickModels = remember(availableModels, thread, selectedModel, snapshot) {
        buildList {
            availableModels.firstOrNull { it.isDefault }?.let(::add)
            recentModelsForThread(snapshot?.threads ?: emptyList(), thread, availableModels, sameWorkspaceOnly = true)
                .filter { it.id != selectedModel && none { existing -> existing.id == it.id } }
                .take(3)
                .forEach(::add)
            recentModelsForThread(snapshot?.threads ?: emptyList(), thread, availableModels, sameWorkspaceOnly = false)
                .filter { it.id != selectedModel && none { existing -> existing.id == it.id } }
                .take(5)
                .forEach(::add)
        }
    }

    LaunchedEffect(appModel.launchState.selectedReasoningEffort(serverId), selectedModelDefinition, supportedEfforts) {
        val pendingEffort = appModel.launchState.selectedReasoningEffort(serverId).trim()
        val defaultEffort = selectedModelDefinition?.defaultReasoningEffort
        if (pendingEffort.isEmpty() || defaultEffort == null || supportedEfforts.isEmpty()) {
            return@LaunchedEffect
        }
        if (supportedEfforts.none { effortLabel(it.reasoningEffort) == pendingEffort }) {
            appModel.launchState.updateReasoningEffort(
                effortLabel(defaultEffort),
                serverId = serverId,
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
            text = "Quick Switch",
            color = LitterTheme.textSecondary,
            fontSize = 11.sp,
        )

        LazyRow(
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(vertical = 4.dp),
        ) {
            items(quickModels) { model ->
                val isSelected = model.id == selectedModel
                FilterChip(
                    selected = isSelected,
                    onClick = {
                        appModel.launchState.updateSelectedModel(model.id, serverId = serverId)
                        appModel.launchState.updateReasoningEffort(
                            model.defaultReasoningEffort.let(::effortLabel),
                            serverId = serverId,
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
        } else if (onBrowseAllModels != null) {
            TextButton(onClick = onBrowseAllModels) {
                Text("Browse all models", color = LitterTheme.accent)
            }
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
                            appModel.launchState.updateReasoningEffort(effort, serverId = serverId)
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

        // Plan + Fast mode toggles
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            val isPlan = thread?.collaborationMode == AppModeKind.PLAN
            FilterChip(
                selected = isPlan,
                onClick = {
                    val next = if (isPlan) AppModeKind.DEFAULT else AppModeKind.PLAN
                    onToggleMode?.invoke(next)
                },
                label = { Text("Plan", fontSize = 10.sp) },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = LitterTheme.accent,
                    selectedLabelColor = Color.Black,
                ),
            )
            Spacer(Modifier.weight(1f))
            Text("Fast mode", color = LitterTheme.textSecondary, fontSize = 11.sp)
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

@Composable
private fun ModelBrowserSheet(
    thread: AppThreadSnapshot?,
    server: uniffi.codex_mobile_client.AppServerSnapshot?,
    availableModels: List<uniffi.codex_mobile_client.ModelInfo>,
    onDismiss: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val snapshot by appModel.snapshot.collectAsState()
    val serverId = thread?.key?.serverId
    val preferenceStore = remember(context) { ServerModelPreferenceStore(context) }
    var searchQuery by remember { mutableStateOf("") }
    var pinnedModelIds by remember(serverId) {
        mutableStateOf(serverId?.let(preferenceStore::pinnedModels) ?: emptyList())
    }
    val selectedModel = appModel.launchState.selectedModel(serverId)
        .takeIf { it.isNotBlank() }
        ?: thread?.model
        ?: availableModels.firstOrNull { it.isDefault }?.id
        ?: availableModels.firstOrNull()?.id
    val currentModel = remember(selectedModel, availableModels) {
        availableModels.firstOrNull { it.id == selectedModel }
    }
    val filteredModels = remember(availableModels, searchQuery) {
        val query = searchQuery.trim()
        val sorted = availableModels.sortedWith(
            compareByDescending<uniffi.codex_mobile_client.ModelInfo> { it.isDefault }
                .thenBy { it.displayName.lowercase() },
        )
        if (query.isEmpty()) {
            sorted
        } else {
            sorted.filter { model ->
                model.displayName.contains(query, ignoreCase = true) ||
                    model.id.contains(query, ignoreCase = true) ||
                    model.description.contains(query, ignoreCase = true) ||
                    (headerModelProviderLabel(model)?.contains(query, ignoreCase = true) == true)
            }
        }
    }
    val pinnedModels = remember(pinnedModelIds, availableModels) {
        pinnedModelIds.mapNotNull { pinnedId -> availableModels.firstOrNull { it.id == pinnedId } }
    }
    val workspaceModels = remember(thread, availableModels, snapshot) {
        recentModelsForThread(snapshot?.threads ?: emptyList(), thread, availableModels, sameWorkspaceOnly = true)
    }
    val recentModels = remember(thread, availableModels, snapshot) {
        recentModelsForThread(snapshot?.threads ?: emptyList(), thread, availableModels, sameWorkspaceOnly = false)
            .filterNot { candidate -> workspaceModels.any { it.id == candidate.id } }
    }
    val groupedModels = remember(filteredModels, pinnedModels, workspaceModels, recentModels, searchQuery, server) {
        val hiddenIds = if (searchQuery.isBlank()) {
            (pinnedModels + workspaceModels + recentModels).map { it.id }.toSet()
        } else {
            emptySet()
        }
        groupModelsByProviderForHeader(
            filteredModels.filterNot { it.id in hiddenIds },
            server,
        )
    }
    val selectModel: (uniffi.codex_mobile_client.ModelInfo) -> Unit = { model ->
        appModel.launchState.updateSelectedModel(model.id, serverId = serverId)
        appModel.launchState.updateReasoningEffort(
            effortLabel(model.defaultReasoningEffort),
            serverId = serverId,
        )
    }
    fun togglePinnedModel(model: uniffi.codex_mobile_client.ModelInfo) {
        val targetServerId = serverId ?: return
        pinnedModelIds = preferenceStore.togglePinnedModel(targetServerId, model.id)
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxHeight(0.92f)
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.SpaceBetween,
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Models", color = LitterTheme.textPrimary, fontSize = 16.sp)
            Row(verticalAlignment = Alignment.CenterVertically) {
                if (serverId != null) {
                    TextButton(onClick = {
                        appModel.launchState.updateSelectedModel("", serverId = serverId)
                        appModel.launchState.updateReasoningEffort("", serverId = serverId)
                    }) {
                        Text("Default", color = LitterTheme.textSecondary)
                    }
                    TextButton(onClick = {
                        val refreshServerId = serverId ?: return@TextButton
                        scope.launch {
                            appModel.refreshAvailableModels(refreshServerId)
                        }
                    }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Refresh, contentDescription = "Refresh models", tint = LitterTheme.accent)
                            Spacer(Modifier.width(4.dp))
                            Text("Refresh", color = LitterTheme.accent)
                        }
                    }
                }
                TextButton(onClick = onDismiss) {
                    Text("Done", color = LitterTheme.accent)
                }
            }
        }

        Text(
            text = buildString {
                append(server?.backendKind?.name?.replace('_', ' ')?.lowercase()?.replaceFirstChar { it.uppercase() } ?: "Server")
                append(" • ")
                append(server?.modelCatalog?.availableModelCount ?: availableModels.size)
                append(" models")
                server?.modelCatalog?.defaultModelDisplayName?.takeIf { it.isNotBlank() }?.let { label ->
                    append(" • default ")
                    append(label)
                }
            },
            color = LitterTheme.textSecondary,
            fontSize = 11.sp,
        )

        OutlinedTextField(
            value = searchQuery,
            onValueChange = { searchQuery = it },
            modifier = Modifier.fillMaxWidth(),
            label = { Text("Search models or providers") },
            singleLine = true,
        )

        LazyColumn(
            modifier = Modifier.weight(1f),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (searchQuery.isBlank() && pinnedModels.isNotEmpty()) {
                item("pinned") {
                    ModelBrowserSection(
                        title = "Pinned",
                        models = pinnedModels,
                        selectedModel = selectedModel,
                        onSelect = selectModel,
                        pinnedModelIds = pinnedModelIds.toSet(),
                        onTogglePinned = ::togglePinnedModel,
                    )
                }
            }

            if (searchQuery.isBlank() && workspaceModels.isNotEmpty()) {
                item("workspace") {
                    ModelBrowserSection(
                        title = "This Workspace",
                        models = workspaceModels,
                        selectedModel = selectedModel,
                        onSelect = selectModel,
                        pinnedModelIds = pinnedModelIds.toSet(),
                        onTogglePinned = ::togglePinnedModel,
                    )
                }
            }

            if (searchQuery.isBlank() && recentModels.isNotEmpty()) {
                item("recent") {
                    ModelBrowserSection(
                        title = "Recent",
                        models = recentModels,
                        selectedModel = selectedModel,
                        onSelect = selectModel,
                        pinnedModelIds = pinnedModelIds.toSet(),
                        onTogglePinned = ::togglePinnedModel,
                    )
                }
            }

            groupedModels.forEach { (provider, models) ->
                item(provider) {
                    ModelBrowserSection(
                        title = provider,
                        models = models,
                        selectedModel = selectedModel,
                        onSelect = selectModel,
                        pinnedModelIds = pinnedModelIds.toSet(),
                        onTogglePinned = ::togglePinnedModel,
                    )
                }
            }
        }

        currentModel?.supportedReasoningEfforts?.takeIf { it.isNotEmpty() }?.let { efforts ->
            Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Effort", color = LitterTheme.textSecondary, fontSize = 11.sp)
                LazyRow(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                    items(efforts) { option ->
                        val effort = effortLabel(option.reasoningEffort)
                        FilterChip(
                            selected = appModel.launchState.selectedReasoningEffort(serverId) == effort,
                            onClick = {
                                appModel.launchState.updateReasoningEffort(effort, serverId = serverId)
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
        }
    }
}

@Composable
private fun ModelBrowserSection(
    title: String,
    models: List<uniffi.codex_mobile_client.ModelInfo>,
    selectedModel: String?,
    onSelect: (uniffi.codex_mobile_client.ModelInfo) -> Unit,
    pinnedModelIds: Set<String>,
    onTogglePinned: (uniffi.codex_mobile_client.ModelInfo) -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, color = LitterTheme.textMuted, fontSize = 11.sp)
        Column(
            modifier = Modifier
                .fillMaxWidth()
                .background(LitterTheme.codeBackground, RoundedCornerShape(8.dp)),
        ) {
            models.forEach { model ->
                val isSelected = model.id == selectedModel
                val isPinned = model.id in pinnedModelIds
                Row(
                    modifier = Modifier
                        .fillMaxWidth()
                        .clickable { onSelect(model) }
                        .padding(horizontal = 12.dp, vertical = 10.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text(
                                text = model.displayName.ifBlank { model.id },
                                color = LitterTheme.textPrimary,
                                fontSize = 12.sp,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                            )
                            headerModelProviderLabel(model)?.let { provider ->
                                Spacer(Modifier.width(6.dp))
                                Text(
                                    text = provider,
                                    color = Color.Black,
                                    fontSize = 10.sp,
                                    modifier = Modifier
                                        .background(LitterTheme.accent, RoundedCornerShape(999.dp))
                                        .padding(horizontal = 6.dp, vertical = 2.dp),
                                )
                            }
                        }
                        if (model.description.isNotBlank()) {
                            Text(
                                text = model.description,
                                color = LitterTheme.textSecondary,
                                fontSize = 10.sp,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                    }
                    if (isSelected) {
                        Spacer(Modifier.width(8.dp))
                        Text("Selected", color = LitterTheme.accent, fontSize = 10.sp)
                    } else {
                        Spacer(Modifier.width(8.dp))
                        Text(
                            text = if (isPinned) "Pinned" else "Pin",
                            color = LitterTheme.textSecondary,
                            fontSize = 10.sp,
                            modifier = Modifier.clickable { onTogglePinned(model) },
                        )
                    }
                }
            }
        }
    }
}

private fun recentModelsForThread(
    threads: List<AppThreadSnapshot>,
    thread: AppThreadSnapshot?,
    availableModels: List<uniffi.codex_mobile_client.ModelInfo>,
    sameWorkspaceOnly: Boolean,
): List<uniffi.codex_mobile_client.ModelInfo> {
    val targetServerId = thread?.key?.serverId ?: return emptyList()
    val targetWorkspace = thread.info.cwd
    val sortedThreads = threads.sortedByDescending { it.info.updatedAt ?: 0L }
    val seen = LinkedHashSet<String>()
    val results = ArrayList<uniffi.codex_mobile_client.ModelInfo>()
    for (candidate in sortedThreads) {
        if (candidate.key.serverId != targetServerId) continue
        if (sameWorkspaceOnly && candidate.info.cwd != targetWorkspace) continue
        val modelId = candidate.resolvedModel.trim()
        if (modelId.isEmpty() || !seen.add(modelId)) continue
        val matched = availableModels.firstOrNull { it.id == modelId } ?: continue
        results += matched
    }
    return results
}

private fun groupModelsByProviderForHeader(
    models: List<uniffi.codex_mobile_client.ModelInfo>,
    server: uniffi.codex_mobile_client.AppServerSnapshot?,
): List<Pair<String, List<uniffi.codex_mobile_client.ModelInfo>>> =
    models
        .groupBy { headerModelProviderLabel(it, server) ?: "Other" }
        .toSortedMap(String.CASE_INSENSITIVE_ORDER)
        .map { (provider, providerModels) ->
            provider to providerModels.sortedWith(
                compareByDescending<uniffi.codex_mobile_client.ModelInfo> { it.isDefault }
                    .thenBy { it.displayName.lowercase() },
            )
        }

private fun headerModelProviderLabel(modelId: String): String? {
    val trimmed = modelId.trim()
    val separatorIndex = trimmed.indexOf(':')
    if (separatorIndex <= 0) return null
    return trimmed.substring(0, separatorIndex).trim().ifEmpty { null }
}

private fun headerModelProviderLabel(
    model: uniffi.codex_mobile_client.ModelInfo,
    server: uniffi.codex_mobile_client.AppServerSnapshot? = null,
): String? {
    val trimmed = model.id.trim()
    val separatorIndex = trimmed.indexOf(':')
    if (separatorIndex > 0) {
        return model.description.trim().ifEmpty {
            trimmed.substring(0, separatorIndex).trim()
        }
    }
    return when (server?.backendKind) {
        uniffi.codex_mobile_client.AppServerBackendKind.CODEX -> "Codex"
        uniffi.codex_mobile_client.AppServerBackendKind.OPEN_CODE -> model.description.trim().ifEmpty { "OpenCode" }
        null -> null
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
