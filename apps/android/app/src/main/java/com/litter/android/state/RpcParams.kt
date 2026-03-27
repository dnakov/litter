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
        modelProvider = null,
        serviceTier = null,
        cwd = cwd,
        approvalPolicy = approvalPolicy,
        approvalsReviewer = null,
        sandbox = sandboxMode,
        config = null,
        serviceName = null,
        baseInstructions = null,
        developerInstructions = developerInstructions,
        personality = null,
        ephemeral = null,
        dynamicTools = null,
        mockExperimentalField = null,
        experimentalRawEvents = false,
        persistExtendedHistory = persistHistory,
    )

    fun toThreadResumeParams(threadId: String, cwd: String? = null): ThreadResumeParams =
        ThreadResumeParams(
            threadId = threadId,
            history = null,
            path = null,
            model = model,
            modelProvider = null,
            serviceTier = null,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            approvalsReviewer = null,
            sandbox = sandboxMode,
            config = null,
            baseInstructions = null,
            developerInstructions = developerInstructions,
            personality = null,
            persistExtendedHistory = persistHistory,
        )

    fun toThreadForkParams(sourceThreadId: String, cwd: String? = null): ThreadForkParams =
        ThreadForkParams(
            threadId = sourceThreadId,
            path = null,
            model = model,
            modelProvider = null,
            serviceTier = null,
            cwd = cwd,
            approvalPolicy = approvalPolicy,
            approvalsReviewer = null,
            sandbox = sandboxMode,
            config = null,
            baseInstructions = null,
            developerInstructions = developerInstructions,
            ephemeral = false,
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
            cwd = null,
            approvalPolicy = approvalPolicy,
            approvalsReviewer = null,
            sandboxPolicy = sandboxPolicy,
            model = model,
            serviceTier = serviceTier?.let { it },
            effort = reasoningEffort,
            summary = null,
            personality = null,
            outputSchema = null,
            collaborationMode = null,
        )
    }
}
