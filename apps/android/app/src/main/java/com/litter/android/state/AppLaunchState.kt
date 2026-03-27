package com.litter.android.state

import android.content.Context
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import uniffi.codex_mobile_client.AppThreadSnapshot
import uniffi.codex_mobile_client.AskForApproval
import uniffi.codex_mobile_client.ReadOnlyAccess
import uniffi.codex_mobile_client.SandboxMode
import uniffi.codex_mobile_client.SandboxPolicy

data class AppLaunchStateSnapshot(
    val currentCwd: String = "",
    val selectedModel: String = "",
    val reasoningEffort: String = "",
    val approvalPolicy: String = DEFAULT_APPROVAL_POLICY,
    val sandboxMode: String = DEFAULT_SANDBOX_MODE,
)

private const val PREFS_NAME = "litter.launchState"
private const val APPROVAL_POLICY_KEY = "litter.approvalPolicy"
private const val SANDBOX_MODE_KEY = "litter.sandboxMode"
private const val DEFAULT_APPROVAL_POLICY = "never"
private const val DEFAULT_SANDBOX_MODE = "workspace-write"

class AppLaunchState(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val _snapshot = MutableStateFlow(
        AppLaunchStateSnapshot(
            approvalPolicy = prefs.getString(APPROVAL_POLICY_KEY, DEFAULT_APPROVAL_POLICY)
                ?.trim()
                ?.ifEmpty { DEFAULT_APPROVAL_POLICY }
                ?: DEFAULT_APPROVAL_POLICY,
            sandboxMode = prefs.getString(SANDBOX_MODE_KEY, DEFAULT_SANDBOX_MODE)
                ?.trim()
                ?.ifEmpty { DEFAULT_SANDBOX_MODE }
                ?: DEFAULT_SANDBOX_MODE,
        ),
    )

    val snapshot: StateFlow<AppLaunchStateSnapshot> = _snapshot.asStateFlow()

    fun updateCurrentCwd(cwd: String?) {
        val normalized = cwd.normalizedOrEmpty()
        _snapshot.update { state ->
            if (state.currentCwd == normalized) state else state.copy(currentCwd = normalized)
        }
    }

    fun updateSelectedModel(model: String?) {
        val normalized = model.normalizedOrEmpty()
        _snapshot.update { state ->
            if (state.selectedModel == normalized) state else state.copy(selectedModel = normalized)
        }
    }

    fun updateReasoningEffort(effort: String?) {
        val normalized = effort.normalizedOrEmpty()
        _snapshot.update { state ->
            if (state.reasoningEffort == normalized) state else state.copy(reasoningEffort = normalized)
        }
    }

    fun updateApprovalPolicy(policy: String?) {
        val normalized = policy.normalizedLowercaseOr(default = DEFAULT_APPROVAL_POLICY)
        prefs.edit().putString(APPROVAL_POLICY_KEY, normalized).apply()
        _snapshot.update { state ->
            if (state.approvalPolicy == normalized) state else state.copy(approvalPolicy = normalized)
        }
    }

    fun updateSandboxMode(mode: String?) {
        val normalized = mode.normalizedLowercaseOr(default = DEFAULT_SANDBOX_MODE)
        prefs.edit().putString(SANDBOX_MODE_KEY, normalized).apply()
        _snapshot.update { state ->
            if (state.sandboxMode == normalized) state else state.copy(sandboxMode = normalized)
        }
    }

    fun syncFromThread(thread: AppThreadSnapshot?) {
        updateCurrentCwd(thread?.info?.cwd)
    }

    fun launchConfig(modelOverride: String? = null): AppThreadLaunchConfig {
        val state = snapshot.value
        val selectedModel = modelOverride.normalizedOrNull() ?: state.selectedModel.normalizedOrNull()
        return AppThreadLaunchConfig(
            model = selectedModel,
            approvalPolicy = askForApprovalFromWireValue(state.approvalPolicy),
            sandboxMode = sandboxModeFromWireValue(state.sandboxMode),
            developerInstructions = null,
            persistHistory = true,
        )
    }

    fun approvalPolicyValue(): AskForApproval? = askForApprovalFromWireValue(snapshot.value.approvalPolicy)

    fun sandboxModeValue(): SandboxMode? = sandboxModeFromWireValue(snapshot.value.sandboxMode)

    fun turnSandboxPolicy(): SandboxPolicy? = sandboxModeValue()?.toTurnSandboxPolicy()

    fun threadStartParams(cwd: String, modelOverride: String? = null) =
        launchConfig(modelOverride).toThreadStartParams(cwd.normalizedOrFallback("/"))
            .also { updateCurrentCwd(it.cwd) }

    fun threadResumeParams(
        threadId: String,
        cwdOverride: String? = null,
        modelOverride: String? = null,
    ) = launchConfig(modelOverride).toThreadResumeParams(threadId, resolvedCwdOverride(cwdOverride))

    fun threadForkParams(
        sourceThreadId: String,
        cwdOverride: String? = null,
        modelOverride: String? = null,
    ) = launchConfig(modelOverride).toThreadForkParams(sourceThreadId, resolvedCwdOverride(cwdOverride))
        .also { updateCurrentCwd(it.cwd) }

    private fun resolvedCwdOverride(cwdOverride: String?): String? =
        cwdOverride.normalizedOrNull() ?: snapshot.value.currentCwd.normalizedOrNull()
}

private fun askForApprovalFromWireValue(value: String?): AskForApproval? =
    when (value.normalizedLowercaseOr(default = "")) {
        "untrusted", "unless-trusted" -> AskForApproval.UnlessTrusted
        "on-failure" -> AskForApproval.OnFailure
        "on-request" -> AskForApproval.OnRequest
        "never" -> AskForApproval.Never
        else -> null
    }

private fun sandboxModeFromWireValue(value: String?): SandboxMode? =
    when (value.normalizedLowercaseOr(default = "")) {
        "read-only" -> SandboxMode.READ_ONLY
        "workspace-write" -> SandboxMode.WORKSPACE_WRITE
        "danger-full-access" -> SandboxMode.DANGER_FULL_ACCESS
        else -> null
    }

fun SandboxMode.toTurnSandboxPolicy(): SandboxPolicy =
    when (this) {
        SandboxMode.READ_ONLY -> SandboxPolicy.ReadOnly(
            access = ReadOnlyAccess.FullAccess,
            networkAccess = false,
        )
        SandboxMode.WORKSPACE_WRITE -> SandboxPolicy.WorkspaceWrite(
            writableRoots = emptyList(),
            readOnlyAccess = ReadOnlyAccess.FullAccess,
            networkAccess = false,
            excludeTmpdirEnvVar = false,
            excludeSlashTmp = false,
        )
        SandboxMode.DANGER_FULL_ACCESS -> SandboxPolicy.DangerFullAccess
    }

private fun String?.normalizedOrEmpty(): String = this?.trim().orEmpty()

private fun String?.normalizedOrNull(): String? = normalizedOrEmpty().ifEmpty { null }

private fun String?.normalizedLowercaseOr(default: String): String =
    normalizedOrEmpty().lowercase().ifEmpty { default }

private fun String?.normalizedOrFallback(fallback: String): String =
    normalizedOrEmpty().ifEmpty { fallback }
