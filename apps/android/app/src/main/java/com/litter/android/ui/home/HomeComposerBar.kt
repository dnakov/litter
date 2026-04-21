package com.litter.android.ui.home

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.isImeVisible
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Mic
import androidx.compose.material.icons.filled.OpenInFull
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.litter.android.state.AppComposerPayload
import com.litter.android.state.ComposerImageAttachment
import com.litter.android.state.VoiceTranscriptionManager
import com.litter.android.ui.LitterTextStyle
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.scaled
import java.io.ByteArrayOutputStream
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.AppProject
import uniffi.codex_mobile_client.AuthStatusRequest
import uniffi.codex_mobile_client.ThreadKey

/**
 * Lightweight composer for the home screen. When the user sends, it creates a
 * new thread on (project.serverId, project.cwd), submits the initial turn,
 * and stays on home — the thread streams in the task list.
 */
@OptIn(androidx.compose.foundation.layout.ExperimentalLayoutApi::class)
@Composable
fun HomeComposerBar(
    project: AppProject?,
    onThreadCreated: (ThreadKey) -> Unit,
    onActiveChange: ((Boolean) -> Unit)? = null,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val scope = rememberCoroutineScope()

    var text by remember { mutableStateOf("") }
    var attachedImage by remember { mutableStateOf<ComposerImageAttachment?>(null) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var isSubmitting by remember { mutableStateOf(false) }
    var isFocused by remember { mutableStateOf(false) }
    var showExpanded by remember { mutableStateOf(false) }
    val focusRequester = remember { FocusRequester() }

    // Auto-focus on first composition so the parent's `isComposerActive`
    // flag stays true (it's derived from internal isFocused/text/etc.). Without
    // this, expanding from a collapsed state would immediately collapse back
    // on the next recomposition because nothing has focus yet.
    LaunchedEffect(Unit) {
        runCatching { focusRequester.requestFocus() }
    }

    val transcriptionManager = remember { VoiceTranscriptionManager() }
    val isRecording by transcriptionManager.isRecording.collectAsState()
    val isTranscribing by transcriptionManager.isTranscribing.collectAsState()

    val micPermissionLauncher = rememberLauncherForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) transcriptionManager.startRecording(context)
    }
    val photoPicker = rememberLauncherForActivityResult(
        ActivityResultContracts.PickVisualMedia(),
    ) { uri ->
        uri?.let {
            attachedImage = readAttachmentFromUri(context, it)
        }
    }

    val canSend = !isSubmitting &&
        (text.isNotBlank() || attachedImage != null)

    // IME visibility is authoritative for "the user is interacting with the
    // composer". `isFocused` alone is unreliable because dismissing the
    // keyboard via system back/down doesn't always clear Compose focus, so
    // we omit it and use `imeVisible` instead. The composer stays active
    // while the user has text or an attachment so unsaved work isn't lost
    // when they briefly dismiss the keyboard to scroll.
    val imeVisible = WindowInsets.isImeVisible
    val isActive = imeVisible ||
        text.isNotBlank() ||
        attachedImage != null ||
        isRecording ||
        isTranscribing
    // Only propagate `false` once the composer has actually become active
    // at least once. Otherwise the very first composition (before focus
    // lands) would emit `false` and the parent would collapse us back to
    // the + button on the next frame.
    var hasBeenActive by remember { mutableStateOf(false) }
    LaunchedEffect(isActive) {
        if (isActive) {
            hasBeenActive = true
            onActiveChange?.invoke(true)
        } else if (hasBeenActive) {
            onActiveChange?.invoke(false)
        }
    }

    // Single send path used by both the inline send button and the expanded
    // dialog. Keep in sync if you change thread startup or payload shape.
    val sendCurrent: () -> Unit = {
        val currentProject = project
        if (currentProject == null) {
            errorMessage = "Pick a project before sending."
        } else {
            val payloadText = text.trim()
            val attachmentToSend = attachedImage
            text = ""
            attachedImage = null
            isSubmitting = true
            errorMessage = null
            scope.launch {
                try {
                    val threadKey = appModel.client.startThread(
                        currentProject.serverId,
                        appModel.launchState.threadStartRequest(currentProject.cwd),
                    )
                    com.litter.android.ui.RecentDirectoryStore(context)
                        .record(currentProject.serverId, currentProject.cwd)
                    val payload = AppComposerPayload(
                        text = payloadText,
                        additionalInputs = listOfNotNull(attachmentToSend?.toUserInput()),
                        approvalPolicy = appModel.launchState.approvalPolicyValue(threadKey),
                        sandboxPolicy = appModel.launchState.turnSandboxPolicy(threadKey),
                        model = appModel.launchState.snapshot.value.selectedModel.trim().ifEmpty { null },
                        reasoningEffort = null,
                        serviceTier = null,
                    )
                    appModel.startTurn(threadKey, payload)
                    appModel.refreshSnapshot()
                    onThreadCreated(threadKey)
                } catch (e: Exception) {
                    errorMessage = e.message ?: "Failed to start thread"
                    text = payloadText
                    attachedImage = attachmentToSend
                } finally {
                    isSubmitting = false
                }
            }
        }
    }

    Column(modifier = Modifier.fillMaxWidth()) {
        if (errorMessage != null) {
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 14.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = errorMessage ?: "",
                    color = LitterTheme.warning,
                    fontSize = LitterTextStyle.caption.scaled,
                    modifier = Modifier.weight(1f),
                )
                IconButton(onClick = { errorMessage = null }) {
                    Icon(
                        imageVector = Icons.Default.Close,
                        contentDescription = "Dismiss",
                        tint = LitterTheme.textMuted,
                        modifier = Modifier.size(14.dp),
                    )
                }
            }
        }

        if (attachedImage != null) {
            val bytes = attachedImage?.data
            val bitmap = remember(bytes) {
                bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
            }
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(start = 16.dp, end = 16.dp, top = 8.dp),
            ) {
                Box {
                    bitmap?.let { bmp ->
                        androidx.compose.foundation.Image(
                            bitmap = bmp.asImageBitmap(),
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
                            imageVector = Icons.Default.Close,
                            contentDescription = "Remove attachment",
                            tint = Color.White,
                            modifier = Modifier.size(14.dp),
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
            }
        }

        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(horizontal = 12.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (!isRecording && !isTranscribing && !isSubmitting) {
                IconButton(
                    onClick = {
                        photoPicker.launch(
                            PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly),
                        )
                    },
                    modifier = Modifier.size(36.dp),
                ) {
                    Icon(
                        imageVector = Icons.Default.Add,
                        contentDescription = "Attach image",
                        tint = LitterTheme.textPrimary,
                    )
                }
            }

            Row(
                modifier = Modifier
                    .weight(1f)
                    .heightIn(min = 36.dp, max = 120.dp)
                    .background(LitterTheme.codeBackground, RoundedCornerShape(18.dp))
                    .padding(horizontal = 14.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Box(modifier = Modifier.weight(1f)) {
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
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(end = 24.dp)
                            .focusRequester(focusRequester)
                            .onFocusChanged { isFocused = it.isFocused },
                    )

                    val shouldShowExpand = (text.contains('\n') || text.length > 60) &&
                        !isRecording && !isTranscribing
                    if (shouldShowExpand) {
                        IconButton(
                            onClick = { showExpanded = true },
                            modifier = Modifier
                                .align(Alignment.TopEnd)
                                .size(20.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.OpenInFull,
                                contentDescription = "Expand composer",
                                tint = LitterTheme.textSecondary,
                                modifier = Modifier.size(12.dp),
                            )
                        }
                    }
                }

                when {
                    canSend -> {
                        Spacer(Modifier.width(8.dp))
                        IconButton(
                            onClick = sendCurrent,
                            modifier = Modifier
                                .size(32.dp)
                                .clip(CircleShape)
                                .background(LitterTheme.accent, CircleShape),
                        ) {
                            Icon(
                                imageVector = Icons.AutoMirrored.Filled.Send,
                                contentDescription = "Send",
                                tint = Color.Black,
                                modifier = Modifier.size(16.dp),
                            )
                        }
                    }

                    isRecording -> {
                        Spacer(Modifier.width(8.dp))
                        IconButton(
                            onClick = {
                                val currentProject = project ?: run {
                                    transcriptionManager.cancelRecording()
                                    return@IconButton
                                }
                                scope.launch {
                                    val auth = runCatching {
                                        appModel.client.authStatus(
                                            currentProject.serverId,
                                            AuthStatusRequest(
                                                includeToken = true,
                                                refreshToken = false,
                                            ),
                                        )
                                    }.getOrNull()
                                    val transcript = transcriptionManager.stopAndTranscribe(
                                        authMethod = auth?.authMethod,
                                        authToken = auth?.authToken,
                                    )
                                    transcript?.let {
                                        text = if (text.isBlank()) it else "$text $it"
                                    }
                                }
                            },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Stop,
                                contentDescription = "Stop recording",
                                tint = LitterTheme.accentStrong,
                            )
                        }
                    }

                    isTranscribing || isSubmitting -> {
                        Spacer(Modifier.width(8.dp))
                        CircularProgressIndicator(
                            strokeWidth = 2.dp,
                            color = LitterTheme.accent,
                            modifier = Modifier.size(18.dp),
                        )
                    }

                    else -> {
                        Spacer(Modifier.width(8.dp))
                        IconButton(
                            onClick = {
                                micPermissionLauncher.launch(android.Manifest.permission.RECORD_AUDIO)
                            },
                            modifier = Modifier.size(32.dp),
                        ) {
                            Icon(
                                imageVector = Icons.Default.Mic,
                                contentDescription = "Record",
                                tint = LitterTheme.textSecondary,
                                modifier = Modifier.size(18.dp),
                            )
                        }
                    }
                }
            }
        }

        if (showExpanded) {
            com.litter.android.ui.conversation.ComposerExpandedDialog(
                text = text,
                onTextChange = { text = it },
                onSend = sendCurrent,
                onDismiss = {
                    showExpanded = false
                    scope.launch {
                        kotlinx.coroutines.delay(80)
                        runCatching { focusRequester.requestFocus() }
                    }
                },
                canSend = text.isNotBlank() || attachedImage != null,
            )
        }
    }
}

private fun readAttachmentFromUri(context: Context, uri: Uri): ComposerImageAttachment? {
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
