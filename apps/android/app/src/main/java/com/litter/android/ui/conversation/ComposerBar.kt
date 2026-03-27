package com.litter.android.ui.conversation

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
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
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.Text
import androidx.compose.material3.rememberModalBottomSheetState
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
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.sp
import com.litter.android.state.ComposerImageAttachment
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
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.TurnInterruptParams

/** Slash command definitions matching iOS. */
internal data class SlashCommand(val name: String, val description: String)
internal data class SlashInvocation(val command: SlashCommand, val args: String?)

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
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ComposerBar(
    threadKey: ThreadKey,
    activeTurnId: String?,
    contextPercent: Int,
    isThinking: Boolean,
    rateLimits: uniffi.codex_mobile_client.RateLimitSnapshot? = null,
    onToggleModelSelector: (() -> Unit)? = null,
    onNavigateToSessions: (() -> Unit)? = null,
    onShowDirectoryPicker: (() -> Unit)? = null,
    onShowRenameDialog: ((String?) -> Unit)? = null,
    onShowPermissionsSheet: (() -> Unit)? = null,
    onShowExperimentalSheet: (() -> Unit)? = null,
    onShowSkillsSheet: (() -> Unit)? = null,
    onSlashError: ((String) -> Unit)? = null,
    pendingUserInput: PendingUserInputRequest? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val composerPrefillRequest by appModel.composerPrefillRequest.collectAsState()
    var text by remember { mutableStateOf("") }
    var attachedImage by remember { mutableStateOf<ComposerImageAttachment?>(null) }
    var showAttachMenu by remember { mutableStateOf(false) }
    val transcriptionManager = remember { VoiceTranscriptionManager() }
    val isRecording by transcriptionManager.isRecording.collectAsState()
    val isTranscribing by transcriptionManager.isTranscribing.collectAsState()
    val photoPicker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
        uri ?: return@rememberLauncherForActivityResult
        attachedImage = readAttachmentFromUri(context, uri)
    }
    val cameraLauncher = rememberLauncherForActivityResult(ActivityResultContracts.TakePicturePreview()) { bitmap ->
        bitmap ?: return@rememberLauncherForActivityResult
        attachedImage = prepareBitmapAttachment(bitmap)
    }

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

    // Only consume edit-message prefill for the intended thread.
    LaunchedEffect(composerPrefillRequest?.requestId, threadKey) {
        val prefill = composerPrefillRequest ?: return@LaunchedEffect
        if (prefill.threadKey != threadKey) return@LaunchedEffect
        text = prefill.text
        attachedImage = null
        appModel.clearComposerPrefill(prefill.requestId)
    }

    fun dispatchSlashCommand(commandName: String, args: String?): Boolean {
        when (commandName) {
            "model" -> onToggleModelSelector?.invoke()
            "new" -> onShowDirectoryPicker?.invoke()
            "resume" -> onNavigateToSessions?.invoke()
            "rename" -> onShowRenameDialog?.invoke(args)
            "skills" -> onShowSkillsSheet?.invoke()
            "permissions" -> onShowPermissionsSheet?.invoke()
            "experimental" -> onShowExperimentalSheet?.invoke()
            "fork" -> scope.launch {
                try {
                    val cwd = appModel.snapshot.value?.threads?.find { it.key == threadKey }?.info?.cwd
                    appModel.store.forkThreadFromMessage(
                        threadKey,
                        0u,
                        appModel.launchState.threadForkParams(
                            sourceThreadId = threadKey.threadId,
                            cwdOverride = cwd,
                            modelOverride = appModel.launchState.snapshot.value.selectedModel.trim().ifEmpty { null },
                        ),
                    )
                } catch (e: Exception) {
                    onSlashError?.invoke(e.message ?: "Failed to fork conversation")
                }
            }
            "review" -> scope.launch {
                try {
                    appModel.rpc.reviewStart(
                        threadKey.serverId,
                        uniffi.codex_mobile_client.ReviewStartParams(
                            threadId = threadKey.threadId,
                            target = uniffi.codex_mobile_client.ReviewTarget.UncommittedChanges,
                            delivery = null,
                        ),
                    )
                } catch (e: Exception) {
                    onSlashError?.invoke(e.message ?: "Failed to start review")
                }
            }
            else -> return false
        }
        return true
    }

    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface)
            .imePadding(),
    ) {
        if (attachedImage != null) {
            val previewBitmap = remember(attachedImage?.data) {
                attachedImage?.data?.let { bytes -> BitmapFactory.decodeByteArray(bytes, 0, bytes.size) }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp),
            ) {
                Box {
                    previewBitmap?.let { bitmap ->
                        androidx.compose.foundation.Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Attached image",
                            modifier = Modifier
                                .size(60.dp)
                                .clip(RoundedCornerShape(8.dp)),
                        )
                    }
                    IconButton(
                        onClick = { attachedImage = null },
                        modifier = Modifier
                            .align(Alignment.TopEnd)
                            .size(22.dp)
                            .background(Color.Black.copy(alpha = 0.6f), CircleShape),
                    ) {
                        Icon(
                            Icons.Default.Close,
                            contentDescription = "Remove attachment",
                            tint = Color.White,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
            }
        }

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
        // Input row
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.Bottom,
        ) {
            if (!isRecording && !isTranscribing && !isThinking) {
                IconButton(
                    onClick = { showAttachMenu = true },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(
                        Icons.Default.Add,
                        contentDescription = "Attach image",
                        tint = LitterTheme.textPrimary,
                    )
                }
            }

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
                                if (dispatchSlashCommand(cmd.name, args = null)) {
                                    text = ""
                                    attachedImage = null
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

            // Send / stop button
            val canSend = (text.isNotBlank() || attachedImage != null) && !isThinking
            IconButton(
                onClick = {
                    if (isThinking) {
                        val turnId = activeTurnId ?: return@IconButton
                        scope.launch {
                            try {
                                appModel.rpc.turnInterrupt(
                                    threadKey.serverId,
                                    TurnInterruptParams(threadId = threadKey.threadId, turnId = turnId),
                                )
                            } catch (_: Exception) {}
                        }
                        return@IconButton
                    }
                    if (!canSend) return@IconButton
                    parseSlashCommandInvocation(text)?.let { invocation ->
                        if (dispatchSlashCommand(invocation.command.name, invocation.args)) {
                            text = ""
                            attachedImage = null
                            return@IconButton
                        }
                    }
                    // Apply pending overrides from HeaderBar
                    val launchState = appModel.launchState.snapshot.value
                    val pendingModel = launchState.selectedModel.trim().ifEmpty { null }
                    val effort = launchState.reasoningEffort.trim().ifEmpty { null }?.let(::reasoningEffortFromServerValue)
                    val tier = if (HeaderOverrides.pendingFastMode) ServiceTier.FAST else null
                    val attachmentToSend = attachedImage
                    val payload = AppComposerPayload(
                        text = text.trim(),
                        additionalInputs = listOfNotNull(attachmentToSend?.toUserInput()),
                        approvalPolicy = appModel.launchState.approvalPolicyValue(),
                        sandboxPolicy = appModel.launchState.turnSandboxPolicy(),
                        model = pendingModel,
                        reasoningEffort = effort,
                        serviceTier = tier,
                    )
                    text = ""
                    attachedImage = null
                    scope.launch {
                        try {
                            appModel.startTurn(threadKey, payload)
                        } catch (e: Exception) {
                            // Restore text on failure
                            text = payload.text
                            attachedImage = attachmentToSend
                        }
                    }
                },
                enabled = isThinking || canSend,
                modifier = Modifier
                    .size(36.dp)
                    .clip(CircleShape)
                    .background(
                        when {
                            isThinking -> LitterTheme.danger
                            canSend -> LitterTheme.accent
                            else -> Color.Transparent
                        },
                        CircleShape,
                    ),
            ) {
                Icon(
                    imageVector = if (isThinking) Icons.Default.Stop else Icons.AutoMirrored.Filled.Send,
                    contentDescription = if (isThinking) "Interrupt" else "Send",
                    tint = when {
                        isThinking -> Color.White
                        canSend -> Color.Black
                        else -> LitterTheme.textMuted
                    },
                    modifier = Modifier.size(18.dp),
                )
            }
        }

        val hasIndicators = contextPercent > 0 || rateLimits?.primary != null || rateLimits?.secondary != null
        if (hasIndicators) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 16.dp, bottom = 6.dp),
                horizontalArrangement = Arrangement.End,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                rateLimits?.primary?.let { window ->
                    RateLimitBadge(window)
                    Spacer(Modifier.width(6.dp))
                }
                rateLimits?.secondary?.let { window ->
                    RateLimitBadge(window)
                    Spacer(Modifier.width(6.dp))
                }
                if (contextPercent > 0) {
                    ContextBadge(contextPercent)
                }
            }
        }
    }

    if (showAttachMenu) {
        ModalBottomSheet(
            onDismissRequest = { showAttachMenu = false },
            sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true),
            containerColor = LitterTheme.background,
        ) {
            Column(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 16.dp, vertical = 12.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp),
            ) {
                Text(
                    text = "Attach",
                    color = LitterTheme.textPrimary,
                    fontSize = 18.sp,
                    fontWeight = FontWeight.SemiBold,
                )

                AttachmentActionRow(
                    title = "Photo Library",
                    onClick = {
                        showAttachMenu = false
                        photoPicker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
                    },
                )

                AttachmentActionRow(
                    title = "Take Photo",
                    onClick = {
                        showAttachMenu = false
                        cameraLauncher.launch(null)
                    },
                )
            }
        }
    }
}

private fun reasoningEffortFromServerValue(value: String): ReasoningEffort? =
    when (value.trim().lowercase()) {
        "none" -> ReasoningEffort.NONE
        "minimal" -> ReasoningEffort.MINIMAL
        "low" -> ReasoningEffort.LOW
        "medium" -> ReasoningEffort.MEDIUM
        "high" -> ReasoningEffort.HIGH
        "xhigh" -> ReasoningEffort.X_HIGH
        else -> null
    }

@Composable
private fun AttachmentActionRow(
    title: String,
    onClick: () -> Unit,
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .background(LitterTheme.surface, RoundedCornerShape(18.dp))
            .clickable(onClick = onClick)
            .padding(horizontal = 16.dp, vertical = 14.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Text(title, color = LitterTheme.textPrimary, fontSize = 14.sp, fontWeight = FontWeight.Medium)
    }
}

private fun readAttachmentFromUri(context: android.content.Context, uri: Uri): ComposerImageAttachment? {
    val resolver = context.contentResolver
    val bytes = resolver.openInputStream(uri)?.use { it.readBytes() } ?: return null
    val mimeType = resolver.getType(uri).orEmpty()
    return prepareImageAttachment(bytes, mimeType)
}

private fun prepareBitmapAttachment(bitmap: Bitmap): ComposerImageAttachment? {
    val output = ByteArrayOutputStream()
    val format = if (bitmap.hasAlpha()) Bitmap.CompressFormat.PNG else Bitmap.CompressFormat.JPEG
    val mimeType = if (bitmap.hasAlpha()) "image/png" else "image/jpeg"
    val quality = if (bitmap.hasAlpha()) 100 else 85
    if (!bitmap.compress(format, quality, output)) return null
    return ComposerImageAttachment(output.toByteArray(), mimeType)
}

private fun prepareImageAttachment(bytes: ByteArray, mimeTypeHint: String): ComposerImageAttachment? {
    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size) ?: return null
    val inferredMime = mimeTypeHint.lowercase()
    if (inferredMime == "image/png" && bitmap.hasAlpha()) {
        return ComposerImageAttachment(bytes, "image/png")
    }
    return prepareBitmapAttachment(bitmap)
}

internal fun parseSlashCommandInvocation(text: String): SlashInvocation? {
    val firstLine = text.lineSequence().firstOrNull()?.trim().orEmpty()
    if (!firstLine.startsWith("/")) return null
    val commandText = firstLine.drop(1).trim()
    if (commandText.isEmpty()) return null
    val parts = commandText.split(Regex("\\s+"), limit = 2)
    val command = SLASH_COMMANDS.firstOrNull { it.name == parts.first().lowercase() } ?: return null
    val args = parts.getOrNull(1)?.trim()?.takeIf { it.isNotEmpty() }
    return SlashInvocation(command = command, args = args)
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
