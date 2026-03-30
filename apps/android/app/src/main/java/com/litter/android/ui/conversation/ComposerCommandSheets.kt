package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AbsolutePath
import uniffi.codex_mobile_client.AppAskForApproval
import uniffi.codex_mobile_client.AppListExperimentalFeaturesRequest
import uniffi.codex_mobile_client.AppListSkillsRequest
import uniffi.codex_mobile_client.AppWriteConfigValueRequest
import uniffi.codex_mobile_client.ExperimentalFeature
import uniffi.codex_mobile_client.JsonValue
import uniffi.codex_mobile_client.JsonValueKind
import uniffi.codex_mobile_client.AppMergeStrategy
import uniffi.codex_mobile_client.AppSandboxMode
import uniffi.codex_mobile_client.SkillMetadata

private data class ComposerPermissionPreset(
    val title: String,
    val description: String,
    val approvalPolicy: AppAskForApproval,
    val sandboxMode: AppSandboxMode,
)

private val composerPermissionPresets = listOf(
    ComposerPermissionPreset(
        title = "Read Only",
        description = "Ask before commands and run in read-only sandbox",
        approvalPolicy = AppAskForApproval.OnRequest,
        sandboxMode = AppSandboxMode.READ_ONLY,
    ),
    ComposerPermissionPreset(
        title = "Auto",
        description = "No prompts and workspace-write sandbox",
        approvalPolicy = AppAskForApproval.Never,
        sandboxMode = AppSandboxMode.WORKSPACE_WRITE,
    ),
    ComposerPermissionPreset(
        title = "Full Access",
        description = "No prompts and danger-full-access sandbox",
        approvalPolicy = AppAskForApproval.Never,
        sandboxMode = AppSandboxMode.DANGER_FULL_ACCESS,
    ),
)

@Composable
fun ComposerPermissionsSheet(onDismiss: () -> Unit) {
    val appModel = LocalAppModel.current
    val launchState by appModel.launchState.snapshot.collectAsState()
    val selectedApproval = remember(launchState.approvalPolicy) { appModel.launchState.approvalPolicyValue() }
    val selectedSandbox = remember(launchState.sandboxMode) { appModel.launchState.sandboxModeValue() }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .imePadding()
            .padding(16.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        SheetHeader(title = "Permissions", onDismiss = onDismiss)
        composerPermissionPresets.forEachIndexed { index, preset ->
            val isSelected = preset.approvalPolicy == selectedApproval && preset.sandboxMode == selectedSandbox
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                    .clickable {
                        appModel.launchState.updateApprovalPolicy(
                            when (preset.approvalPolicy) {
                                AppAskForApproval.OnRequest -> "on-request"
                                AppAskForApproval.Never -> "never"
                                AppAskForApproval.OnFailure -> "on-failure"
                                AppAskForApproval.UnlessTrusted -> "unless-trusted"
                                is AppAskForApproval.Granular -> null
                            },
                        )
                        appModel.launchState.updateSandboxMode(
                            when (preset.sandboxMode) {
                                AppSandboxMode.READ_ONLY -> "read-only"
                                AppSandboxMode.WORKSPACE_WRITE -> "workspace-write"
                                AppSandboxMode.DANGER_FULL_ACCESS -> "danger-full-access"
                            },
                        )
                        onDismiss()
                    }
                    .padding(horizontal = 14.dp, vertical = 12.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(preset.title, color = LitterTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                    Text(preset.description, color = LitterTheme.textSecondary, fontSize = 12.sp)
                }
                if (isSelected) {
                    Icon(
                        Icons.Default.Check,
                        contentDescription = null,
                        tint = LitterTheme.accent,
                        modifier = Modifier.size(18.dp),
                    )
                }
            }
            if (index < composerPermissionPresets.lastIndex) {
                Spacer(Modifier.height(2.dp))
            }
        }
    }
}

@Composable
fun ComposerExperimentalSheet(
    serverId: String,
    onDismiss: () -> Unit,
    onError: (String) -> Unit,
) {
    val appModel = LocalAppModel.current
    val scope = rememberCoroutineScope()
    var features by remember(serverId) { mutableStateOf<List<ExperimentalFeature>>(emptyList()) }
    var isLoading by remember(serverId) { mutableStateOf(true) }
    var reloadToken by remember(serverId) { mutableIntStateOf(0) }

    LaunchedEffect(serverId, reloadToken) {
        isLoading = true
        runCatching {
            appModel.client.listExperimentalFeatures(
                serverId,
                AppListExperimentalFeaturesRequest(cursor = null, limit = 200u),
            )
        }.onSuccess { featuresResult ->
            features = featuresResult.sortedBy { (it.displayName ?: it.name).lowercase() }
        }.onFailure { error ->
            features = emptyList()
            onError(error.message ?: "Failed to load experimental features")
        }
        isLoading = false
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxSize(fraction = 0.9f)
            .imePadding()
            .padding(16.dp),
    ) {
        SheetHeader(
            title = "Experimental",
            leadingActionLabel = "Reload",
            onLeadingAction = { reloadToken += 1 },
            onDismiss = onDismiss,
        )
        Spacer(Modifier.height(12.dp))
        when {
            isLoading -> {
                Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = LitterTheme.accent, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                }
            }

            features.isEmpty() -> {
                Text("No experimental features available", color = LitterTheme.textMuted, fontSize = 13.sp)
            }

            else -> {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(features, key = { it.name }) { feature ->
                        Row(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Column(modifier = Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(feature.displayName ?: feature.name, color = LitterTheme.textPrimary, fontSize = 14.sp)
                                feature.description?.takeIf { it.isNotBlank() }?.let { description ->
                                    Text(description, color = LitterTheme.textSecondary, fontSize = 12.sp)
                                }
                            }
                            Switch(
                                checked = feature.enabled,
                                onCheckedChange = { enabled ->
                                    val previous = feature.enabled
                                    features = features.map {
                                        if (it.name == feature.name) {
                                            ExperimentalFeature(
                                                name = it.name,
                                                stage = it.stage,
                                                displayName = it.displayName,
                                                description = it.description,
                                                announcement = it.announcement,
                                                enabled = enabled,
                                                defaultEnabled = it.defaultEnabled,
                                            )
                                        } else {
                                            it
                                        }
                                    }
                                    scope.launch {
                                        runCatching {
                                            appModel.client.writeConfigValue(
                                                serverId,
                                                AppWriteConfigValueRequest(
                                                    keyPath = "features.${feature.name}",
                                                    value = JsonValue(
                                                        kind = JsonValueKind.BOOL,
                                                        boolValue = enabled,
                                                        i64Value = null,
                                                        u64Value = null,
                                                        f64Value = null,
                                                        stringValue = null,
                                                        arrayItems = null,
                                                        objectEntries = null,
                                                    ),
                                                    mergeStrategy = AppMergeStrategy.UPSERT,
                                                    filePath = null,
                                                    expectedVersion = null,
                                                ),
                                            )
                                        }.onFailure { error ->
                                            features = features.map {
                                                if (it.name == feature.name) {
                                                    ExperimentalFeature(
                                                        name = it.name,
                                                        stage = it.stage,
                                                        displayName = it.displayName,
                                                        description = it.description,
                                                        announcement = it.announcement,
                                                        enabled = previous,
                                                        defaultEnabled = it.defaultEnabled,
                                                    )
                                                } else {
                                                    it
                                                }
                                            }
                                            onError(error.message ?: "Failed to update experimental feature")
                                        }
                                    }
                                },
                                colors = SwitchDefaults.colors(checkedTrackColor = LitterTheme.accent),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun ComposerSkillsSheet(
    serverId: String,
    cwd: String,
    onDismiss: () -> Unit,
    onError: (String) -> Unit,
) {
    val appModel = LocalAppModel.current
    var skills by remember(serverId, cwd) { mutableStateOf<List<SkillMetadata>>(emptyList()) }
    var isLoading by remember(serverId, cwd) { mutableStateOf(true) }
    var reloadToken by remember(serverId, cwd) { mutableIntStateOf(0) }

    LaunchedEffect(serverId, cwd, reloadToken) {
        isLoading = true
        runCatching {
            appModel.client.listSkills(
                serverId,
                AppListSkillsRequest(
                    cwds = listOf(cwd),
                    forceReload = reloadToken > 0,
                ),
            )
        }.onSuccess { skillResults ->
            skills = skillResults.sortedBy { it.name.lowercase() }
        }.onFailure { error ->
            skills = emptyList()
            onError(error.message ?: "Failed to load skills")
        }
        isLoading = false
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .fillMaxSize(fraction = 0.9f)
            .imePadding()
            .padding(16.dp),
    ) {
        SheetHeader(
            title = "Skills",
            leadingActionLabel = "Reload",
            onLeadingAction = { reloadToken += 1 },
            onDismiss = onDismiss,
        )
        Spacer(Modifier.height(12.dp))
        when {
            isLoading -> {
                Box(Modifier.fillMaxWidth().padding(vertical = 32.dp), contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = LitterTheme.accent, modifier = Modifier.size(22.dp), strokeWidth = 2.dp)
                }
            }

            skills.isEmpty() -> {
                Text("No skills available for this workspace", color = LitterTheme.textMuted, fontSize = 13.sp)
            }

            else -> {
                LazyColumn(verticalArrangement = Arrangement.spacedBy(8.dp)) {
                    items(skills, key = { "${it.path.value}#${it.name}" }) { skill ->
                        Column(
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface.copy(alpha = 0.72f), RoundedCornerShape(12.dp))
                                .padding(horizontal = 14.dp, vertical = 12.dp),
                            verticalArrangement = Arrangement.spacedBy(4.dp),
                        ) {
                            Row(verticalAlignment = Alignment.CenterVertically) {
                                Text(skill.name, color = LitterTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
                                Spacer(Modifier.weight(1f))
                                if (skill.enabled) {
                                    Text(
                                        "enabled",
                                        color = LitterTheme.accent,
                                        fontSize = 11.sp,
                                        modifier = Modifier
                                            .background(LitterTheme.accent.copy(alpha = 0.14f), RoundedCornerShape(999.dp))
                                            .padding(horizontal = 6.dp, vertical = 2.dp),
                                    )
                                }
                            }
                            Text(skill.description, color = LitterTheme.textSecondary, fontSize = 12.sp)
                            Text(skill.path.value, color = LitterTheme.textMuted, fontSize = 11.sp)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun SheetHeader(
    title: String,
    leadingActionLabel: String? = null,
    onLeadingAction: (() -> Unit)? = null,
    onDismiss: () -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (leadingActionLabel != null && onLeadingAction != null) {
            TextButton(onClick = onLeadingAction) {
                Text(leadingActionLabel, color = LitterTheme.accent)
            }
        } else {
            Spacer(Modifier.width(64.dp))
        }
        Spacer(Modifier.weight(1f))
        Text(title, color = LitterTheme.textPrimary, fontSize = 17.sp, fontWeight = FontWeight.SemiBold)
        Spacer(Modifier.weight(1f))
        TextButton(onClick = onDismiss) {
            Text("Done", color = LitterTheme.accent)
        }
    }
    HorizontalDivider(color = LitterTheme.divider, modifier = Modifier.padding(top = 8.dp))
}
