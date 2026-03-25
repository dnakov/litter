package com.litter.android.ui.conversation

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.LaunchedEffect
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
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppComposerPayload
import com.litter.android.state.VoiceTranscriptionManager
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import uniffi.codex_mobile_client.FuzzyFileSearchParams
import uniffi.codex_mobile_client.PendingUserInputAnswer
import uniffi.codex_mobile_client.PendingUserInputRequest
import uniffi.codex_mobile_client.ReasoningEffort
import uniffi.codex_mobile_client.ServiceTier
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.BerkeleyMono
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey

/** Slash command definitions matching iOS. */
private data class SlashCommand(val name: String, val description: String)

private val SLASH_COMMANDS = listOf(
    SlashCommand("model", "Change model or reasoning effort"),
    SlashCommand("new", "Start a new session"),
    SlashCommand("fork", "Fork this conversation"),
    SlashCommand("rename", "Rename this session"),
    SlashCommand("review", "Start a code review"),
    SlashCommand("resume", "Browse sessions"),
    SlashCommand("skills", "List available skills"),
    SlashCommand("permissions", "Change approval policy"),
    SlashCommand("experimental", "Toggle experimental features"),
)

/**
 * Bottom composer bar with text input, send, voice, slash commands,
 * @file search, and inline pending user input.
 */
@Composable
fun ComposerBar(
    threadKey: ThreadKey,
    contextPercent: Int,
    isThinking: Boolean,
    rateLimits: uniffi.codex_mobile_client.RateLimitSnapshot? = null,
    onToggleModelSelector: (() -> Unit)? = null,
    onNavigateToSessions: (() -> Unit)? = null,
    onShowDirectoryPicker: (() -> Unit)? = null,
    pendingUserInput: PendingUserInputRequest? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    var text by remember { mutableStateOf("") }
    val transcriptionManager = remember { VoiceTranscriptionManager() }
    val isRecording by transcriptionManager.isRecording.collectAsState()
    val isTranscribing by transcriptionManager.isTranscribing.collectAsState()

    // Slash command state
    val slashQuery by remember {
        derivedStateOf {
            if (text.startsWith("/")) text.removePrefix("/").lowercase() else null
        }
    }
    val filteredCommands by remember {
        derivedStateOf {
            val q = slashQuery ?: return@derivedStateOf emptyList()
            SLASH_COMMANDS.filter { it.name.startsWith(q) || q.isEmpty() }
        }
    }
    var showSlashMenu by remember { mutableStateOf(false) }
    LaunchedEffect(slashQuery) { showSlashMenu = slashQuery != null && filteredCommands.isNotEmpty() }

    // @file search state
    var fileSearchResults by remember { mutableStateOf<List<String>>(emptyList()) }
    var showFileMenu by remember { mutableStateOf(false) }
    var fileSearchJob by remember { mutableStateOf<Job?>(null) }
    LaunchedEffect(text) {
        val atIdx = text.lastIndexOf('@')
        if (atIdx >= 0 && atIdx < text.length - 1 && !text.substring(atIdx).contains(' ')) {
            val query = text.substring(atIdx + 1)
            fileSearchJob?.cancel()
            fileSearchJob = scope.launch {
                delay(140) // debounce
                try {
                    val cwd = appModel.snapshot.value?.threads?.find { it.key == threadKey }?.info?.cwd ?: "~"
                    val resp = appModel.rpc.fuzzyFileSearch(
                        threadKey.serverId,
                        FuzzyFileSearchParams(query = query, roots = listOf(cwd), cancellationToken = null),
                    )
                    fileSearchResults = resp.files.map { it.path }.take(8)
                    showFileMenu = fileSearchResults.isNotEmpty()
                } catch (_: Exception) {
                    showFileMenu = false
                }
            }
        } else {
            showFileMenu = false
        }
    }

    // Pending user input answers
    var userInputAnswers by remember { mutableStateOf(mapOf<String, String>()) }

    // Check for prefill text (from edit message flow)
    LaunchedEffect(Unit) {
        appModel.clearComposerPrefill()?.let { prefill ->
            text = prefill
        }
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface)
            .imePadding(),
    ) {
        // Inline pending user input prompt (above composer)
        if (pendingUserInput != null) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(LitterTheme.codeBackground)
                    .padding(12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                for (question in pendingUserInput.questions) {
                    Text(question.question, color = LitterTheme.textPrimary, fontSize = LitterTextStyle.footnote.scaled)
                    if (question.options.isNotEmpty()) {
                        Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                            for (option in question.options) {
                                val selected = userInputAnswers[question.id] == option.label
                                Text(
                                    text = option.label,
                                    color = if (selected) Color.Black else LitterTheme.textPrimary,
                                    fontSize = LitterTextStyle.caption.scaled,
                                    fontWeight = if (selected) FontWeight.Bold else FontWeight.Normal,
                                    modifier = Modifier
                                        .background(
                                            if (selected) LitterTheme.accent else LitterTheme.surface,
                                            RoundedCornerShape(12.dp),
                                        )
                                        .clickable { userInputAnswers = userInputAnswers + (question.id to option.label) }
                                        .padding(horizontal = 10.dp, vertical = 4.dp),
                                )
                            }
                        }
                    } else {
                        var answer by remember { mutableStateOf("") }
                        BasicTextField(
                            value = answer,
                            onValueChange = {
                                answer = it
                                userInputAnswers = userInputAnswers + (question.id to it)
                            },
                            textStyle = TextStyle(color = LitterTheme.textPrimary, fontSize = LitterTextStyle.footnote.scaled),
                            cursorBrush = SolidColor(LitterTheme.accent),
                            modifier = Modifier
                                .fillMaxWidth()
                                .background(LitterTheme.surface, RoundedCornerShape(8.dp))
                                .padding(8.dp),
                        )
                    }
                }
                Text(
                    text = "Submit",
                    color = Color.Black,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier
                        .background(LitterTheme.accent, RoundedCornerShape(8.dp))
                        .clickable {
                            scope.launch {
                                val answers = pendingUserInput.questions.map { q ->
                                    PendingUserInputAnswer(
                                        questionId = q.id,
                                        answers = listOfNotNull(userInputAnswers[q.id]),
                                    )
                                }
                                appModel.store.respondToUserInput(pendingUserInput.id, answers)
                                userInputAnswers = emptyMap()
                            }
                        }
                        .padding(horizontal = 16.dp, vertical = 6.dp),
                )
            }
        }
        // Context bar: rate limit badges + context badge (matching iOS)
        val hasIndicators = contextPercent > 0 || rateLimits?.primary != null
        if (hasIndicators) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                // Rate limit badges
                rateLimits?.primary?.let { window ->
                    RateLimitBadge(window)
                    Spacer(Modifier.width(6.dp))
                }
                rateLimits?.secondary?.let { window ->
                    RateLimitBadge(window)
                    Spacer(Modifier.width(6.dp))
                }
                // Context usage badge
                if (contextPercent > 0) {
                    ContextBadge(contextPercent)
                }
            }
        }

        // Input row
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            // Voice transcription button
            IconButton(
                onClick = {
                    if (isRecording) {
                        scope.launch {
                            // Get auth token from server account
                            val snap = appModel.snapshot.value
                            val server = snap?.servers?.firstOrNull { it.serverId == threadKey.serverId }
                            // Extract auth token from server account
                            val account = snap?.servers?.firstOrNull { it.serverId == threadKey.serverId }?.account
                            val token = when (account) {
                                is uniffi.codex_mobile_client.Account.Chatgpt -> "" // ChatGPT uses cookies, not bearer
                                is uniffi.codex_mobile_client.Account.ApiKey -> "" // No direct token access
                                else -> ""
                            }
                            val transcript = transcriptionManager.stopAndTranscribe(token)
                            transcript?.let { text = if (text.isBlank()) it else "$text $it" }
                        }
                    } else {
                        transcriptionManager.startRecording(context)
                    }
                },
                modifier = Modifier.size(36.dp),
            ) {
                Icon(
                    Icons.Default.Mic,
                    contentDescription = "Voice",
                    tint = when {
                        isRecording -> LitterTheme.danger
                        isTranscribing -> LitterTheme.warning
                        else -> LitterTheme.textSecondary
                    },
                )
            }

            // Text field
            Box(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 36.dp, max = 120.dp)
                    .background(LitterTheme.codeBackground, RoundedCornerShape(18.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
            ) {
                if (text.isEmpty()) {
                    Text(
                        text = "Message\u2026",
                        color = LitterTheme.textMuted,
                        fontSize = LitterTextStyle.body.scaled,
                    )
                }
                BasicTextField(
                    value = text,
                    onValueChange = { text = it },
                    textStyle = TextStyle(
                        color = LitterTheme.textPrimary,
                        fontSize = LitterTextStyle.body.scaled,
                        fontFamily = LitterTheme.monoFont,
                    ),
                    cursorBrush = SolidColor(LitterTheme.accent),
                    modifier = Modifier.fillMaxWidth(),
                )

                // Slash command popup
                DropdownMenu(
                    expanded = showSlashMenu,
                    onDismissRequest = { showSlashMenu = false },
                ) {
                    for (cmd in filteredCommands) {
                        DropdownMenuItem(
                            text = {
                                Row(verticalAlignment = Alignment.CenterVertically) {
                                    Text("/${cmd.name}", color = LitterTheme.accent, fontSize = LitterTextStyle.footnote.scaled, fontWeight = FontWeight.Medium)
                                    Spacer(Modifier.width(8.dp))
                                    Text(cmd.description, color = LitterTheme.textMuted, fontSize = 11.sp)
                                }
                            },
                            onClick = {
                                showSlashMenu = false
                                text = ""
                                when (cmd.name) {
                                    "model" -> onToggleModelSelector?.invoke()
                                    "new" -> onShowDirectoryPicker?.invoke()
                                    "resume" -> onNavigateToSessions?.invoke()
                                    "fork" -> scope.launch {
                                        try {
                                            val config = com.litter.android.state.AppThreadLaunchConfig(model = null)
                                            val cwd = appModel.snapshot.value?.threads?.find { it.key == threadKey }?.info?.cwd ?: "~"
                                            appModel.store.forkThreadFromMessage(threadKey, 0u, config.toThreadForkParams(threadKey.threadId, cwd))
                                        } catch (_: Exception) {}
                                    }
                                    "rename" -> {
                                        // Will be handled by ConversationScreen showing a dialog
                                    }
                                    "review" -> scope.launch {
                                        try {
                                            appModel.rpc.reviewStart(threadKey.serverId, uniffi.codex_mobile_client.ReviewStartParams(threadId = threadKey.threadId, target = uniffi.codex_mobile_client.ReviewTarget.UncommittedChanges, delivery = null))
                                        } catch (_: Exception) {}
                                    }
                                    // skills, permissions, experimental — open respective sheets
                                }
                            },
                        )
                    }
                }

                // @file search popup
                DropdownMenu(
                    expanded = showFileMenu,
                    onDismissRequest = { showFileMenu = false },
                ) {
                    for (path in fileSearchResults) {
                        DropdownMenuItem(
                            text = { Text(path, color = LitterTheme.textPrimary, fontSize = 12.sp, fontFamily = LitterTheme.monoFont) },
                            onClick = {
                                showFileMenu = false
                                val atIdx = text.lastIndexOf('@')
                                if (atIdx >= 0) {
                                    text = text.substring(0, atIdx) + "@$path "
                                }
                            },
                        )
                    }
                }
            }

            Spacer(Modifier.width(4.dp))

            // Send button
            val canSend = text.isNotBlank() && !isThinking
            IconButton(
                onClick = {
                    if (!canSend) return@IconButton
                    // Apply pending overrides from HeaderBar
                    val effort = HeaderOverrides.pendingEffort?.let { e ->
                        try { ReasoningEffort.valueOf(e.uppercase()) } catch (_: Exception) { null }
                    }
                    val tier = if (HeaderOverrides.pendingFastMode) ServiceTier.FAST else null
                    val payload = AppComposerPayload(
                        text = text.trim(),
                        model = HeaderOverrides.pendingModel,
                        reasoningEffort = effort,
                        serviceTier = tier,
                    )
                    text = ""
                    scope.launch {
                        try {
                            appModel.startTurn(threadKey, payload)
                        } catch (e: Exception) {
                            // Restore text on failure
                            text = payload.text
                        }
                    }
                },
                enabled = canSend,
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(
                        if (canSend) LitterTheme.accent else Color.Transparent,
                        CircleShape,
                    ),
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send,
                    contentDescription = "Send",
                    tint = if (canSend) Color.Black else LitterTheme.textMuted,
                    modifier = Modifier.size(18.dp),
                )
            }
        }
    }
}

// ── Rate Limit Badge (matching iOS RateLimitBadgeView) ───────────────────────

@Composable
private fun RateLimitBadge(window: uniffi.codex_mobile_client.RateLimitWindow) {
    val remaining = 100 - window.usedPercent
    val label = window.windowDurationMins?.let { mins ->
        when {
            mins >= 1440 -> "${mins / 1440}d"
            mins >= 60 -> "${mins / 60}h"
            else -> "${mins}m"
        }
    } ?: "?"
    val color = when {
        remaining <= 10 -> LitterTheme.danger
        remaining <= 30 -> LitterTheme.warning
        else -> LitterTheme.textMuted
    }

    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier
            .background(color.copy(alpha = 0.12f), RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 2.dp),
    ) {
        Text(
            text = "$label: $remaining%",
            color = color,
            fontSize = 9.sp,
            fontWeight = FontWeight.SemiBold,
            fontFamily = LitterTheme.monoFont,
        )
    }
}

// ── Context Badge (matching iOS ContextBadgeView) ────────────────────────────

@Composable
private fun ContextBadge(percent: Int) {
    val tint = when {
        percent <= 15 -> LitterTheme.danger
        percent <= 35 -> LitterTheme.warning
        else -> LitterTheme.success
    }

    Box(
        modifier = Modifier
            .size(width = 35.dp, height = 16.dp)
            .background(Color.Transparent, RoundedCornerShape(4.dp))
            .border(1.2.dp, tint.copy(alpha = 0.5f), RoundedCornerShape(4.dp)),
        contentAlignment = Alignment.CenterStart,
    ) {
        // Fill bar
        Box(
            modifier = Modifier
                .fillMaxHeight()
                .fillMaxWidth(fraction = percent / 100f)
                .background(tint.copy(alpha = 0.25f), RoundedCornerShape(4.dp)),
        )
        // Number overlay
        Text(
            text = "$percent",
            color = tint,
            fontSize = 9.sp,
            fontWeight = FontWeight.ExtraBold,
            fontFamily = LitterTheme.monoFont,
            modifier = Modifier.align(Alignment.Center),
        )
    }
}
