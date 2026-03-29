package com.litter.android.state

import uniffi.codex_mobile_client.AskForApproval
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.SandboxMode
import uniffi.codex_mobile_client.SandboxPolicy
import uniffi.codex_mobile_client.ServiceTier
import uniffi.codex_mobile_client.ThreadForkParams
import uniffi.codex_mobile_client.ThreadResumeParams
import uniffi.codex_mobile_client.ThreadStartParams
import uniffi.codex_mobile_client.TurnStartParams
import uniffi.codex_mobile_client.UserInput

data class ComposerImageAttachment(
    val data: ByteArray,
    val mimeType: String,
) {
    val dataUri: String
        get() = "data:$mimeType;base64,${android.util.Base64.encodeToString(data, android.util.Base64.NO_WRAP)}"

    fun toUserInput(): UserInput.Image = UserInput.Image(url = dataUri)
}

/**
 * UI-facing config for creating/resuming threads.
 * Converts to Rust RPC param types.
 */
data class AppThreadLaunchConfig(
    val model: String? = null,
    val approvalPolicy: AskForApproval? = null,
    val sandboxMode: SandboxMode? = null,
    val developerInstructions: String? = null,
    val persistHistory: Boolean = true,
) {
    fun toThreadStartParams(cwd: String): ThreadStartParams = ThreadStartParams(
        model = model,
        cwd = cwd,
        approvalPolicy = approvalPolicy,
        sandbox = sandboxMode,
        developerInstructions = developerInstructions,
        persistExtendedHistory = persistHistory,
    )

    fun toThreadResumeParams(threadId: String, cwd: String? = null): ThreadResumeParams =
        ThreadResumeParams(
            threadId = threadId,
            model = model,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            sandbox = sandboxMode,
            developerInstructions = developerInstructions,
            persistExtendedHistory = persistHistory,
        )

    fun toThreadForkParams(sourceThreadId: String, cwd: String? = null): ThreadForkParams =
        ThreadForkParams(
            threadId = sourceThreadId,
            model = model,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            sandbox = sandboxMode,
            developerInstructions = developerInstructions,
            persistExtendedHistory = persistHistory,
        )
}

/**
 * UI-facing payload for composing a message.
 * Converts to Rust [TurnStartParams].
 */
data class AppComposerPayload(
    val text: String,
    val additionalInputs: List<UserInput> = emptyList(),
    val approvalPolicy: AskForApproval? = null,
    val sandboxPolicy: SandboxPolicy? = null,
    val model: String? = null,
    val reasoningEffort: ReasoningEffort? = null,
    val serviceTier: ServiceTier? = null,
) {
    fun toTurnStartParams(threadId: String): TurnStartParams {
        val input = additionalInputs.toMutableList()
        if (text.isNotBlank()) {
            input.add(0, UserInput.Text(text = text, textElements = emptyList()))
        }

        return TurnStartParams(
            threadId = threadId,
            input = input,
            approvalPolicy = approvalPolicy,
            sandboxPolicy = sandboxPolicy,
            model = model,
            serviceTier = serviceTier,
            effort = reasoningEffort,
        )
    }
}
