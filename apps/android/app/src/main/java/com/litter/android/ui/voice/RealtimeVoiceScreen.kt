package com.litter.android.ui.voice

import android.Manifest
import android.content.pm.PackageManager
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.VolumeUp
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.OutlinedTextFieldDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.draw.blur
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.platform.LocalContext
import androidx.core.content.ContextCompat
import com.litter.android.state.OpenAIApiKeyStore
import com.litter.android.state.VoiceRuntimeController
import com.litter.android.ui.LitterTheme
import com.litter.android.ui.LocalAppModel
import com.litter.android.ui.rememberStickyFollowTail
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.Account
import uniffi.codex_mobile_client.AppVoiceSessionPhase
import uniffi.codex_mobile_client.AppVoiceSpeaker
import uniffi.codex_mobile_client.AppVoiceTranscriptEntry
import uniffi.codex_mobile_client.AppRefreshAccountRequest
import uniffi.codex_mobile_client.ThreadKey

@Composable
fun RealtimeVoiceScreen(
    threadKey: ThreadKey,
    onBack: () -> Unit,
) {
    val appModel = LocalAppModel.current
    val context = LocalContext.current
    val apiKeyStore = remember(context) { OpenAIApiKeyStore(context.applicationContext) }
    val voiceController = remember { VoiceRuntimeController.shared }
    val activeSession by voiceController.activeVoiceSession.collectAsState()
    val snapshot by appModel.snapshot.collectAsState()
    val scope = rememberCoroutineScope()
    val voiceSession = snapshot?.voiceSession
    val phase = voiceSession?.phase ?: AppVoiceSessionPhase.CONNECTING
    val inputLevel = activeSession?.inputLevel ?: 0f
    val outputLevel = activeSession?.outputLevel ?: 0f
    val transcriptEntries = remember(voiceSession?.transcriptEntries) {
        voiceSession?.transcriptEntries?.filter { it.text.trim().isNotEmpty() }.orEmpty()
    }
    val transcriptListState = rememberLazyListState()
    val shouldFollowTail = rememberStickyFollowTail(
        listState = transcriptListState,
        resetKey = threadKey,
        bufferItems = 1,
    )

    var hasCheckedAuth by remember { mutableStateOf(false) }
    var hasStartedRealtime by remember { mutableStateOf(false) }
    var apiKey by remember { mutableStateOf("") }
    var apiKeyError by remember { mutableStateOf<String?>(null) }
    var isSavingKey by remember { mutableStateOf(false) }
    var hasStoredApiKey by remember { mutableStateOf(apiKeyStore.hasStoredKey()) }
    var isSpeakerOn by remember { mutableStateOf(true) }
    var hasMicPermission by remember {
        mutableStateOf(
            ContextCompat.checkSelfPermission(
                context,
                Manifest.permission.RECORD_AUDIO,
            ) == PackageManager.PERMISSION_GRANTED,
        )
    }

    val micPermissionLauncher = rememberLauncherForActivityResult(
        contract = ActivityResultContracts.RequestPermission(),
    ) { granted ->
        hasMicPermission = granted
    }

    val server = remember(snapshot, threadKey) {
        snapshot?.servers?.firstOrNull { it.serverId == threadKey.serverId }
    }
    val needsApiKey = hasCheckedAuth && server?.isLocal == true && !hasStoredApiKey
    val phaseColor = voicePhaseColor(phase)
    val transcriptTailSignature = remember(transcriptEntries) {
        var hash = 17
        transcriptEntries.takeLast(4).forEach { entry ->
            hash = 31 * hash + entry.hashCode()
        }
        hash = 31 * hash + transcriptEntries.size
        hash
    }

    LaunchedEffect(threadKey) {
        try {
            appModel.client.refreshAccount(
                threadKey.serverId,
                AppRefreshAccountRequest(refreshToken = false),
            )
            appModel.refreshSnapshot()
            apiKeyError = null
        } catch (e: Exception) {
            apiKeyError = e.localizedMessage
        }
        hasStoredApiKey = apiKeyStore.hasStoredKey()
        hasCheckedAuth = true
    }

    LaunchedEffect(Unit) {
        if (!hasMicPermission) {
            micPermissionLauncher.launch(Manifest.permission.RECORD_AUDIO)
        }
    }

    LaunchedEffect(hasStoredApiKey, hasCheckedAuth, hasMicPermission) {
        if (hasCheckedAuth && hasStoredApiKey && hasMicPermission && !hasStartedRealtime) {
            hasStartedRealtime = true
            voiceController.startVoiceOnThread(appModel, threadKey)
        }
    }

    LaunchedEffect(threadKey, transcriptTailSignature) {
        if (shouldFollowTail && transcriptEntries.isNotEmpty()) {
            transcriptListState.scrollToItem(transcriptEntries.lastIndex)
        }
    }

    DisposableEffect(threadKey, appModel, voiceController) {
        onDispose {
            scope.launch {
                voiceController.stopVoiceSessionIfActive(appModel, threadKey)
            }
        }
    }

    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(LitterTheme.background),
    ) {
        VoiceEdgeGlow(
            intensity = voiceGlowIntensity(
                phase = phase,
                inputLevel = inputLevel,
                outputLevel = outputLevel,
            ),
            phase = phase,
        )

        Column(
            modifier = Modifier.fillMaxSize(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Spacer(Modifier.weight(1f))

            TranscriptContent(
                entries = transcriptEntries,
                phase = phase,
                phaseColor = phaseColor,
                inputLevel = inputLevel,
                outputLevel = outputLevel,
                listState = transcriptListState,
                modifier = Modifier
                    .weight(1.15f)
                    .fillMaxWidth()
                    .padding(horizontal = 32.dp),
            )

            voiceSession?.handoffThreadKey?.let { handoffKey ->
                InlineHandoffView(
                    threadKey = handoffKey,
                    modifier = Modifier
                        .fillMaxWidth()
                        .heightIn(max = 220.dp)
                        .padding(horizontal = 18.dp, vertical = 18.dp),
                )
            }

            Spacer(Modifier.weight(1f))

            val footerError = voiceSession?.lastError ?: if (!hasMicPermission) "Microphone permission required" else null
            if (!footerError.isNullOrBlank()) {
                Text(
                    text = footerError,
                    color = LitterTheme.danger,
                    fontSize = 12.sp,
                    textAlign = TextAlign.Center,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(horizontal = 24.dp),
                )
                Spacer(Modifier.height(12.dp))
            }

            BottomControls(
                isSpeakerOn = isSpeakerOn,
                onToggleSpeaker = {
                    val next = !isSpeakerOn
                    isSpeakerOn = next
                    voiceController.setSpeakerEnabled(next)
                },
                onEnd = {
                    scope.launch {
                        voiceController.stopActiveVoiceSession(appModel)
                        onBack()
                    }
                },
                modifier = Modifier.padding(bottom = 40.dp),
            )
        }

        if (needsApiKey) {
            RealtimeApiKeyPrompt(
                apiKey = apiKey,
                apiKeyError = apiKeyError,
                isSavingKey = isSavingKey,
                onApiKeyChange = { apiKey = it },
                onSave = {
                    val trimmedKey = apiKey.trim()
                    if (trimmedKey.isEmpty() || isSavingKey) return@RealtimeApiKeyPrompt
                    if (server?.isLocal != true) {
                        apiKeyError = "API keys are only saved on the local server."
                        return@RealtimeApiKeyPrompt
                    }

                    isSavingKey = true
                    apiKeyError = null
                    hasStartedRealtime = true

                    scope.launch {
                        try {
                            apiKeyStore.save(trimmedKey)
                            if (server?.account is Account.ApiKey) {
                                appModel.client.logoutAccount(threadKey.serverId)
                            }
                            voiceController.stopActiveVoiceSession(appModel)
                            appModel.restartLocalServer()
                            hasStoredApiKey = apiKeyStore.hasStoredKey()
                            if (!hasStoredApiKey) {
                                hasStartedRealtime = false
                                apiKeyError = "API key did not persist locally."
                                return@launch
                            }
                            delay(150)
                            voiceController.startVoiceOnThread(appModel, threadKey)
                            apiKey = ""
                        } catch (e: Exception) {
                            hasStartedRealtime = false
                            apiKeyError = e.localizedMessage ?: "Failed to save API key"
                        } finally {
                            isSavingKey = false
                        }
                    }
                },
                modifier = Modifier.align(Alignment.Center),
            )
        }
    }
}

@Composable
private fun TranscriptContent(
    entries: List<AppVoiceTranscriptEntry>,
    phase: AppVoiceSessionPhase,
    phaseColor: Color,
    inputLevel: Float,
    outputLevel: Float,
    listState: androidx.compose.foundation.lazy.LazyListState,
    modifier: Modifier = Modifier,
) {
    Column(
        modifier = modifier,
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(16.dp),
    ) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            VoiceScreenPulsingDot(
                color = phaseColor,
                isActive = phase == AppVoiceSessionPhase.LISTENING || phase == AppVoiceSessionPhase.SPEAKING,
            )

            Text(
                text = voicePhaseLabel(phase),
                color = phaseColor,
                fontSize = 12.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 2.sp,
                fontFamily = LitterTheme.monoFont,
            )
        }

        Box(
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
            contentAlignment = Alignment.Center,
        ) {
            if (entries.isEmpty()) {
                AudioWaveformView(
                    level = if (phase == AppVoiceSessionPhase.LISTENING) inputLevel else outputLevel,
                    tint = phaseColor,
                    modifier = Modifier
                        .fillMaxWidth(0.58f)
                        .height(40.dp),
                )
            } else {
                LazyColumn(
                    state = listState,
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.Center,
                    contentPadding = PaddingValues(vertical = 12.dp),
                    modifier = Modifier.fillMaxSize(),
                ) {
                    itemsIndexed(
                        items = entries,
                        key = { _, entry -> entry.itemId },
                    ) { index, entry ->
                        TranscriptLine(
                            entry = entry,
                            recencyIndex = entries.lastIndex - index,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun TranscriptLine(
    entry: AppVoiceTranscriptEntry,
    recencyIndex: Int,
) {
    val isUser = entry.speaker == AppVoiceSpeaker.USER
    val opacity = when (recencyIndex) {
        0 -> 0.96f
        1 -> 0.72f
        2 -> 0.5f
        else -> 0.34f
    }

    Text(
        text = entry.text,
        color = Color.White.copy(alpha = opacity),
        fontSize = if (isUser) 17.sp else 22.sp,
        fontWeight = if (isUser) FontWeight.Normal else FontWeight.Medium,
        textAlign = TextAlign.Center,
        lineHeight = if (isUser) 24.sp else 30.sp,
        modifier = Modifier
            .fillMaxWidth()
            .padding(vertical = 9.dp),
    )
}

@Composable
private fun BottomControls(
    isSpeakerOn: Boolean,
    onToggleSpeaker: () -> Unit,
    onEnd: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(40.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            IconButton(
                onClick = onToggleSpeaker,
                modifier = Modifier
                    .size(52.dp)
                    .background(Color.White.copy(alpha = 0.1f), CircleShape),
            ) {
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.VolumeUp,
                    contentDescription = "Speaker route",
                    tint = Color.White,
                )
            }

            Text(
                text = if (isSpeakerOn) "Speaker" else "Phone",
                color = Color.White.copy(alpha = if (isSpeakerOn) 1f else 0.4f),
                fontSize = 11.sp,
                fontFamily = LitterTheme.monoFont,
            )
        }

        IconButton(
            onClick = onEnd,
            modifier = Modifier
                .size(64.dp)
                .background(LitterTheme.danger, CircleShape),
        ) {
            Icon(
                imageVector = Icons.Default.Close,
                contentDescription = "End call",
                tint = Color.White,
                modifier = Modifier.size(20.dp),
            )
        }
    }
}

@Composable
private fun RealtimeApiKeyPrompt(
    apiKey: String,
    apiKeyError: String?,
    isSavingKey: Boolean,
    onApiKeyChange: (String) -> Unit,
    onSave: () -> Unit,
    modifier: Modifier = Modifier,
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .background(Color.Black.copy(alpha = 0.34f)),
    ) {
        Column(
            verticalArrangement = Arrangement.spacedBy(14.dp),
            modifier = modifier
                .padding(horizontal = 20.dp)
                .widthIn(max = 420.dp)
                .clip(RoundedCornerShape(24.dp))
                .background(Color.Black.copy(alpha = 0.34f))
                .border(1.dp, Color.White.copy(alpha = 0.08f), RoundedCornerShape(24.dp))
                .padding(18.dp),
        ) {
            Text(
                text = "Realtime needs an API key",
                color = Color.White,
                fontSize = 20.sp,
                fontWeight = FontWeight.SemiBold,
            )

            Text(
                text = "Enter your OpenAI API key for this device. Litter will store it in the local Codex environment as OPENAI_API_KEY.",
                color = Color.White.copy(alpha = 0.78f),
                fontSize = 12.sp,
                lineHeight = 18.sp,
            )

            OutlinedTextField(
                value = apiKey,
                onValueChange = onApiKeyChange,
                placeholder = {
                    Text(
                        text = "sk-...",
                        color = Color.White.copy(alpha = 0.5f),
                        fontFamily = LitterTheme.monoFont,
                    )
                },
                singleLine = true,
                visualTransformation = PasswordVisualTransformation(),
                colors = OutlinedTextFieldDefaults.colors(
                    focusedContainerColor = Color.White.copy(alpha = 0.08f),
                    unfocusedContainerColor = Color.White.copy(alpha = 0.08f),
                    disabledContainerColor = Color.White.copy(alpha = 0.08f),
                    focusedBorderColor = Color.White.copy(alpha = 0.14f),
                    unfocusedBorderColor = Color.White.copy(alpha = 0.14f),
                    focusedTextColor = Color.White,
                    unfocusedTextColor = Color.White,
                    cursorColor = Color.White,
                ),
                shape = RoundedCornerShape(14.dp),
                modifier = Modifier.fillMaxWidth(),
            )

            if (!apiKeyError.isNullOrBlank()) {
                Text(
                    text = apiKeyError,
                    color = Color(0xFFFF8A8A),
                    fontSize = 12.sp,
                    lineHeight = 18.sp,
                )
            }

            Button(
                onClick = onSave,
                enabled = apiKey.isNotBlank() && !isSavingKey,
                colors = ButtonDefaults.buttonColors(
                    containerColor = Color.White.copy(alpha = 0.12f),
                    contentColor = Color.White,
                    disabledContainerColor = Color.White.copy(alpha = 0.06f),
                    disabledContentColor = Color.White.copy(alpha = 0.55f),
                ),
                shape = RoundedCornerShape(16.dp),
                modifier = Modifier
                    .fillMaxWidth()
                    .border(1.dp, Color.White.copy(alpha = 0.12f), RoundedCornerShape(16.dp)),
            ) {
                if (isSavingKey) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(14.dp),
                        strokeWidth = 2.dp,
                        color = Color.White,
                    )
                } else {
                    Text(
                        text = "Save API Key",
                        fontSize = 14.sp,
                        fontWeight = FontWeight.SemiBold,
                    )
                }
            }
        }
    }
}

@Composable
private fun VoiceScreenPulsingDot(
    color: Color,
    isActive: Boolean,
) {
    val transition = rememberInfiniteTransition(label = "voice-dot")
    val scale by transition.animateFloat(
        initialValue = if (isActive) 1f else 0.7f,
        targetValue = if (isActive) 1.4f else 0.7f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 800, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "voice-dot-scale",
    )

    Box(
        modifier = Modifier
            .size((8.dp * scale).coerceAtLeast(6.dp))
            .background(color, CircleShape),
    )
}

@Composable
private fun AudioWaveformView(
    level: Float,
    tint: Color,
    modifier: Modifier = Modifier,
) {
    val transition = rememberInfiniteTransition(label = "voice-wave")
    val pulse by transition.animateFloat(
        initialValue = 0.78f,
        targetValue = 1.02f,
        animationSpec = infiniteRepeatable(
            animation = tween(durationMillis = 900, easing = LinearEasing),
            repeatMode = RepeatMode.Reverse,
        ),
        label = "voice-wave-pulse",
    )
    val normalizedLevel = (0.3f + (level * 0.9f)).coerceIn(0.2f, 1f)
    val multipliers = listOf(0.36f, 0.62f, 1f, 0.62f, 0.36f)

    Canvas(modifier = modifier) {
        val spacing = size.width / (multipliers.size * 2f + 1f)
        val barWidth = spacing
        multipliers.forEachIndexed { index, multiplier ->
            val barHeight = size.height * (0.28f + multiplier * normalizedLevel * pulse * 0.6f)
            val left = spacing + index * spacing * 2f
            val top = (size.height - barHeight) / 2f
            drawLine(
                color = tint.copy(alpha = 0.8f),
                start = androidx.compose.ui.geometry.Offset(left, top),
                end = androidx.compose.ui.geometry.Offset(left, top + barHeight),
                strokeWidth = barWidth,
                cap = StrokeCap.Round,
            )
        }
    }
}

@Composable
private fun VoiceEdgeGlow(
    intensity: Float,
    phase: AppVoiceSessionPhase,
) {
    val colors = voicePhaseGlowColors(phase)

    Box(
        modifier = Modifier.fillMaxSize(),
    ) {
        GlowStrokeLayer(colors = colors, intensity = intensity, strokeWidth = 4.dp, blurRadius = 0.dp, alpha = 1f)
        GlowStrokeLayer(colors = colors, intensity = intensity, strokeWidth = 6.dp, blurRadius = 4.dp, alpha = 0.95f)
        GlowStrokeLayer(colors = colors, intensity = intensity, strokeWidth = 8.dp, blurRadius = 12.dp, alpha = 0.82f)
        GlowStrokeLayer(colors = colors, intensity = intensity, strokeWidth = 12.dp, blurRadius = 20.dp, alpha = 0.7f)
    }
}

@Composable
private fun GlowStrokeLayer(
    colors: List<Color>,
    intensity: Float,
    strokeWidth: androidx.compose.ui.unit.Dp,
    blurRadius: androidx.compose.ui.unit.Dp,
    alpha: Float,
) {
    Canvas(
        modifier = Modifier
            .fillMaxSize()
            .blur(blurRadius),
    ) {
        val strokePx = strokeWidth.toPx() + intensity * strokeWidth.toPx() * 0.7f
        val inset = strokePx / 2f
        val cornerRadius = size.minDimension * 0.115f

        drawRoundRect(
            brush = Brush.sweepGradient(colors),
            topLeft = androidx.compose.ui.geometry.Offset(inset, inset),
            size = androidx.compose.ui.geometry.Size(
                width = size.width - strokePx,
                height = size.height - strokePx,
            ),
            cornerRadius = CornerRadius(cornerRadius, cornerRadius),
            style = Stroke(width = strokePx),
            alpha = (intensity * alpha).coerceIn(0f, 1f),
        )
    }
}

private fun voicePhaseLabel(phase: AppVoiceSessionPhase): String =
    when (phase) {
        AppVoiceSessionPhase.CONNECTING -> "CONNECTING"
        AppVoiceSessionPhase.LISTENING -> "LISTENING"
        AppVoiceSessionPhase.SPEAKING -> "SPEAKING"
        AppVoiceSessionPhase.THINKING -> "THINKING"
        AppVoiceSessionPhase.HANDOFF -> "HANDOFF"
        AppVoiceSessionPhase.ERROR -> "ERROR"
    }

private fun voicePhaseColor(phase: AppVoiceSessionPhase): Color =
    when (phase) {
        AppVoiceSessionPhase.CONNECTING -> LitterTheme.accent
        AppVoiceSessionPhase.LISTENING -> LitterTheme.accentStrong
        AppVoiceSessionPhase.SPEAKING,
        AppVoiceSessionPhase.THINKING,
        AppVoiceSessionPhase.HANDOFF,
        -> LitterTheme.warning
        AppVoiceSessionPhase.ERROR -> LitterTheme.danger
    }

private fun voiceGlowIntensity(
    phase: AppVoiceSessionPhase,
    inputLevel: Float,
    outputLevel: Float,
): Float =
    when (phase) {
        AppVoiceSessionPhase.LISTENING -> maxOf(0.3f, inputLevel)
        AppVoiceSessionPhase.SPEAKING -> maxOf(0.3f, outputLevel)
        AppVoiceSessionPhase.THINKING,
        AppVoiceSessionPhase.HANDOFF,
        -> 0.4f
        AppVoiceSessionPhase.CONNECTING -> 0.25f
        AppVoiceSessionPhase.ERROR -> 0.1f
    }

private fun voicePhaseGlowColors(phase: AppVoiceSessionPhase): List<Color> {
    val accent = LitterTheme.accent
    val accentStrong = LitterTheme.accentStrong
    val warning = LitterTheme.warning
    val success = LitterTheme.success
    val danger = LitterTheme.danger

    return when (phase) {
        AppVoiceSessionPhase.LISTENING -> listOf(
            accentStrong,
            accentStrong.copy(alpha = 0.7f),
            accent,
            success,
            accentStrong.copy(alpha = 0.5f),
            accent.copy(alpha = 0.8f),
        )
        AppVoiceSessionPhase.SPEAKING -> listOf(
            warning,
            warning.copy(alpha = 0.7f),
            warning.copy(alpha = 0.9f),
            warning.copy(alpha = 0.5f),
            warning.copy(alpha = 0.8f),
            warning.copy(alpha = 0.6f),
        )
        AppVoiceSessionPhase.THINKING,
        AppVoiceSessionPhase.HANDOFF,
        -> listOf(
            warning.copy(alpha = 0.6f),
            accent.copy(alpha = 0.4f),
            warning.copy(alpha = 0.4f),
            accentStrong.copy(alpha = 0.3f),
            warning.copy(alpha = 0.5f),
            accent.copy(alpha = 0.3f),
        )
        AppVoiceSessionPhase.CONNECTING -> listOf(
            accent.copy(alpha = 0.4f),
            accentStrong.copy(alpha = 0.3f),
            accent.copy(alpha = 0.2f),
            Color.Gray.copy(alpha = 0.2f),
            accent.copy(alpha = 0.3f),
            accentStrong.copy(alpha = 0.2f),
        )
        AppVoiceSessionPhase.ERROR -> listOf(
            danger,
            danger.copy(alpha = 0.6f),
            danger.copy(alpha = 0.5f),
            danger.copy(alpha = 0.4f),
            danger.copy(alpha = 0.3f),
            danger.copy(alpha = 0.5f),
        )
    }
}
