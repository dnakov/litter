package com.litter.android.core.bridge

import org.json.JSONObject

data class SessionSummary(
    val id: String,
    val title: String,
)

data class InitializeResponse(
    val userAgent: String? = null,
)

data class ThreadInfo(
    val id: String,
)

data class ThreadSummary(
    val id: String,
    val preview: String,
    val modelProvider: String,
    val createdAt: Long,
    val updatedAt: Long,
    val cwd: String,
    val cliVersion: String,
)

data class ThreadListResponse(
    val data: List<ThreadSummary>,
    val nextCursor: String? = null,
)

data class ThreadStartResponse(
    val thread: ThreadInfo,
    val model: String? = null,
    val cwd: String? = null,
)

data class ResumedTurn(
    val id: String,
    val items: List<JSONObject>,
)

data class ResumedThread(
    val id: String,
    val turns: List<ResumedTurn>,
)

data class ThreadResumeResponse(
    val thread: ResumedThread,
    val model: String? = null,
    val cwd: String? = null,
)

data class UserInput(
    val type: String,
    val text: String,
)

data class TurnStartResponse(
    val turnId: String? = null,
)

data class ReasoningEffortOption(
    val reasoningEffort: String,
    val description: String,
)

data class CodexModel(
    val id: String,
    val model: String,
    val upgrade: String? = null,
    val displayName: String,
    val description: String,
    val hidden: Boolean,
    val supportedReasoningEfforts: List<ReasoningEffortOption>,
    val defaultReasoningEffort: String,
    val inputModalities: List<String>? = null,
    val supportsPersonality: Boolean? = null,
    val isDefault: Boolean,
)

data class ModelListResponse(
    val data: List<CodexModel>,
    val nextCursor: String? = null,
)

data class CommandExecResponse(
    val exitCode: Int,
    val stdout: String,
    val stderr: String,
)
