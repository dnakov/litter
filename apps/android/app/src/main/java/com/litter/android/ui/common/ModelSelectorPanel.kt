package com.litter.android.ui.common

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Lock
import androidx.compose.material.icons.filled.LockOpen
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.scaled
import uniffi.codex_mobile_client.AppModeKind
import uniffi.codex_mobile_client.AppThreadPermissionPreset
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.ModelInfo
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.threadPermissionPreset

/**
 * Reusable model/reasoning/plan/permissions/fast-mode panel shared by the
 * conversation header (scoped to an existing thread) and the home composer
 * chip (pre-thread, `thread == null`). Mirrors iOS
 * `HeaderView.swift` + `ConversationOptionsSheet.swift`.
 *
 * When `thread` is null:
 *   - Permission toggle operates on `AppLaunchState` defaults (threadKey=null)
 *     so the choice carries through the next `startThread` call.
 *   - Plan toggle is hidden — the collaboration mode is a per-thread field
 *     with no pre-thread equivalent on Android.
 *
 * `onToggleMode` is invoked for Plan chip taps; pass null (or it will be
 * ignored because the chip is hidden) when there's no thread.
 */
@Composable
fun ModelSelectorPanel(
    thread: AppThreadSnapshot?,
    availableModels: List<ModelInfo>,
    onToggleMode: ((AppModeKind) -> Unit)? = null,
    fastMode: Boolean,
    onFastModeChange: (Boolean) -> Unit,
    modifier: Modifier = Modifier,
) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    val selectedModel = launchState.selectedModel
        .takeIf { it.isNotBlank() }
        ?: thread?.model
        ?: availableModels.firstOrNull { it.isDefault }?.id
        ?: availableModels.firstOrNull()?.id
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
        .takeIf { pending ->
            pending.isNotBlank() &&
                supportedEfforts.any { effortLabel(it.reasoningEffort) == pending }
        }
        ?: thread?.reasoningEffort
            ?.takeIf { current ->
                supportedEfforts.any { effortLabel(it.reasoningEffort) == current }
            }
        ?: selectedModelDefinition?.defaultReasoningEffort?.let(::effortLabel)

    LaunchedEffect(launchState.reasoningEffort, selectedModelDefinition, supportedEfforts) {
        val pendingEffort = launchState.reasoningEffort.trim()
        val defaultEffort = selectedModelDefinition?.defaultReasoningEffort
        if (pendingEffort.isEmpty() || defaultEffort == null || supportedEfforts.isEmpty()) {
            return@LaunchedEffect
        }
        if (supportedEfforts.none { effortLabel(it.reasoningEffort) == pendingEffort }) {
            appModel.launchState.updateReasoningEffort(effortLabel(defaultEffort))
        }
    }

    Column(
        modifier = modifier
            .fillMaxWidth()
            .background(LitterTheme.codeBackground)
            .padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        Text(
            text = "Model",
            color = LitterTheme.textSecondary,
            fontSize = LitterTextStyle.caption2.scaled,
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
                            effortLabel(model.defaultReasoningEffort),
                        )
                    },
                    label = {
                        Text(
                            text = model.displayName.ifBlank { model.id },
                            fontSize = LitterTextStyle.caption2.scaled,
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
                fontSize = LitterTextStyle.caption2.scaled,
                modifier = Modifier.padding(vertical = 4.dp),
            )
        }

        Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
            Row(
                horizontalArrangement = Arrangement.spacedBy(6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    "Effort",
                    color = LitterTheme.textSecondary,
                    fontSize = LitterTextStyle.caption2.scaled,
                )
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
                        label = { Text(effort, fontSize = 10f.scaled) },
                        colors = FilterChipDefaults.filterChipColors(
                            selectedContainerColor = LitterTheme.accent,
                            selectedLabelColor = Color.Black,
                        ),
                    )
                }
            }
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(6.dp),
            modifier = Modifier.padding(top = 4.dp),
        ) {
            val threadKey = thread?.key
            if (thread != null && onToggleMode != null) {
                val isPlan = thread.collaborationMode == AppModeKind.PLAN
                FilterChip(
                    selected = isPlan,
                    onClick = {
                        val next = if (isPlan) AppModeKind.DEFAULT else AppModeKind.PLAN
                        onToggleMode(next)
                    },
                    label = { Text("Plan", fontSize = 10f.scaled) },
                    colors = FilterChipDefaults.filterChipColors(
                        selectedContainerColor = LitterTheme.accent,
                        selectedLabelColor = Color.Black,
                    ),
                )
            }

            val currentPreset = run {
                val approval = appModel.launchState.approvalPolicyValue(threadKey)
                    ?: thread?.effectiveApprovalPolicy
                val sandbox = appModel.launchState.turnSandboxPolicy(threadKey)
                    ?: thread?.effectiveSandboxPolicy
                if (approval != null && sandbox != null) {
                    threadPermissionPreset(approval, sandbox)
                } else {
                    null
                }
            }
            val isFullAccess = currentPreset == AppThreadPermissionPreset.FULL_ACCESS
            FilterChip(
                selected = isFullAccess,
                onClick = {
                    if (isFullAccess) {
                        appModel.launchState.updateThreadPermissions(
                            threadKey,
                            approvalPolicy = "on-request",
                            sandboxMode = "workspace-write",
                        )
                    } else {
                        appModel.launchState.updateThreadPermissions(
                            threadKey,
                            approvalPolicy = "never",
                            sandboxMode = "danger-full-access",
                        )
                    }
                },
                leadingIcon = {
                    Icon(
                        imageVector = if (isFullAccess) Icons.Default.LockOpen else Icons.Default.Lock,
                        contentDescription = null,
                        modifier = Modifier.size(12.dp),
                    )
                },
                label = {
                    Text(
                        if (isFullAccess) "Full Access" else "Supervised",
                        fontSize = 10f.scaled,
                    )
                },
                colors = FilterChipDefaults.filterChipColors(
                    selectedContainerColor = LitterTheme.danger,
                    selectedLabelColor = Color.White,
                    selectedLeadingIconColor = Color.White,
                ),
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Fast mode",
                color = LitterTheme.textSecondary,
                fontSize = LitterTextStyle.caption2.scaled,
            )
            Switch(
                checked = fastMode,
                onCheckedChange = onFastModeChange,
                colors = SwitchDefaults.colors(
                    checkedTrackColor = LitterTheme.accent,
                ),
            )
        }
    }
}

internal fun effortLabel(value: ReasoningEffort): String = when (value) {
    ReasoningEffort.NONE -> "none"
    ReasoningEffort.MINIMAL -> "minimal"
    ReasoningEffort.LOW -> "low"
    ReasoningEffort.MEDIUM -> "medium"
    ReasoningEffort.HIGH -> "high"
    ReasoningEffort.X_HIGH -> "xhigh"
}
