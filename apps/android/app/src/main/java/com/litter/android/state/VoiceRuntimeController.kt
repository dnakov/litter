package com.litter.android.state

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.util.Base64
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import uniffi.codex_mobile_client.DynamicToolSpec
import uniffi.codex_mobile_client.JsonObjectEntry
import uniffi.codex_mobile_client.JsonValue
import uniffi.codex_mobile_client.JsonValueKind
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.ThreadRealtimeAppendAudioParams
import uniffi.codex_mobile_client.ThreadRealtimeAudioChunk
import uniffi.codex_mobile_client.ThreadRealtimeStartParams
import uniffi.codex_mobile_client.ThreadRealtimeStopParams
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID
import kotlin.math.max
import kotlin.math.sqrt

/**
 * Full realtime voice session controller with audio I/O, level metering,
 * and handoff dispatch. Shared transcript/phase state comes from Rust AppStore.
 */
class VoiceRuntimeController {

    companion object {
        val shared: VoiceRuntimeController by lazy { VoiceRuntimeController() }
        private const val TARGET_SAMPLE_RATE = 24000
        private const val AEC_SAMPLE_RATE = 48000
        private const val INPUT_DECAY_MS = 450L
        private const val OUTPUT_DECAY_MS = 350L
        private const val INPUT_THRESHOLD = 0.05f
        private const val OUTPUT_THRESHOLD = 0.02f
        private const val LEVEL_SCALE = 3.1f
        private const val CAPTURE_WARMUP_MS = 350L
    }

    // ── State ────────────────────────────────────────────────────────────────

    data class VoiceSessionState(
        val threadKey: ThreadKey,
        val inputLevel: Float = 0f,
        val outputLevel: Float = 0f,
    )

    private val _activeSession = MutableStateFlow<VoiceSessionState?>(null)
    val activeVoiceSession: StateFlow<VoiceSessionState?> = _activeSession.asStateFlow()

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
    private var sessionJob: Job? = null
    private var captureJob: Job? = null
    private var handoffManager: HandoffManager? = null
    private var aecBridge: AecBridge? = null

    // Audio I/O
    private var audioRecord: AudioRecord? = null
    private var audioTrack: AudioTrack? = null
    private var isCapturing = false
    private var audioManager: AudioManager? = null
    private var audioFocusRequest: AudioFocusRequest? = null
    private var previousAudioMode: Int? = null
    private var captureSampleRate = TARGET_SAMPLE_RATE
    private var speakerEnabled = true
    private val playbackLock = Any()
    private val captureLock = Any()
    private val sessionLock = Any()

    // Level decay tokens
    private var inputDecayToken: String? = null
    private var outputDecayToken: String? = null

    // ── Session lifecycle ────────────────────────────────────────────────────

    suspend fun startPinnedLocalVoiceCall(
        appModel: AppModel, cwd: String, model: String? = null, effort: String? = null,
    ) {
        val snap = appModel.snapshot.value ?: return
        val localServer = snap.servers.firstOrNull { it.isLocal } ?: return
        val config = AppThreadLaunchConfig(model = model)
        val threadKey: ThreadKey
        try {
            val resp = appModel.rpc.threadStart(localServer.serverId, config.toThreadStartParams(cwd))
            threadKey = ThreadKey(serverId = localServer.serverId, threadId = resp.thread.id)
        } catch (_: Exception) { return }
        startRealtimeSession(appModel, threadKey)
    }

    suspend fun startVoiceOnThread(appModel: AppModel, key: ThreadKey) {
        startRealtimeSession(appModel, key)
    }

    suspend fun stopActiveVoiceSession(appModel: AppModel) {
        val session = _activeSession.value ?: return
        try {
            appModel.rpc.threadRealtimeStop(
                session.threadKey.serverId,
                ThreadRealtimeStopParams(threadId = session.threadKey.threadId),
            )
        } catch (_: Exception) {}
        cleanup()
    }

    // ── Audio capture ────────────────────────────────────────────────────────

    private data class RecorderConfig(
        val sampleRate: Int,
        val bufferSize: Int,
        val audioRecord: AudioRecord,
    )

    private suspend fun startAudioCapture(appModel: AppModel, threadKey: ThreadKey) {
        synchronized(captureLock) {
            if (isCapturing || captureJob?.isActive == true || audioRecord != null) {
                return
            }
            isCapturing = true
        }
        val manager = appModel.appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
        audioManager = manager
        prepareCommunicationAudio(manager)

        val recorderConfig = createRecorder(manager)
        if (recorderConfig == null) {
            synchronized(captureLock) { isCapturing = false }
            abortRealtimeSession(
                appModel,
                threadKey,
                "Unable to initialize Android microphone capture",
            )
            return
        }

        captureSampleRate = recorderConfig.sampleRate
        val bufferSize = recorderConfig.bufferSize
        audioRecord = recorderConfig.audioRecord

        // Attach Android's platform AEC to the recorder session when available.
        aecBridge = audioRecord?.audioSessionId?.let(AecBridge::attach)

        // Initialize playback
        configureOutputRoute(manager)

        val playbackBufSize = AudioTrack.getMinBufferSize(
            AEC_SAMPLE_RATE, AudioFormat.CHANNEL_OUT_MONO, AudioFormat.ENCODING_PCM_16BIT,
        )
        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_MEDIA)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .setAudioFormat(
                AudioFormat.Builder()
                    .setSampleRate(AEC_SAMPLE_RATE)
                    .setChannelMask(AudioFormat.CHANNEL_OUT_MONO)
                    .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                    .build()
            )
            .setBufferSizeInBytes(if (playbackBufSize > 0) playbackBufSize * 2 else 8192)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()
        audioTrack?.play()

        val recorder = audioRecord
        if (recorder == null || recorder.state != AudioRecord.STATE_INITIALIZED) {
            synchronized(captureLock) { isCapturing = false }
            abortRealtimeSession(
                appModel,
                threadKey,
                "AudioRecord was not initialized for sampleRate=$captureSampleRate",
            )
            return
        }

        try {
            recorder.startRecording()
        } catch (e: IllegalStateException) {
            synchronized(captureLock) { isCapturing = false }
            abortRealtimeSession(
                appModel,
                threadKey,
                "AudioRecord.startRecording failed for sampleRate=$captureSampleRate: ${e.message}",
            )
            return
        }
        isCapturing = true
        val captureStartTime = System.currentTimeMillis()

        captureJob = scope.launch {
            val buffer = ShortArray(bufferSize / 2)
            while (isCapturing) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read <= 0) continue

                // Compute input level (RMS)
                val rms = computeRms(buffer, read)
                val scaledLevel = (rms * LEVEL_SCALE).coerceAtMost(1f)
                updateInputLevel(scaledLevel)

                // Skip capture warmup (first 350ms)
                if (System.currentTimeMillis() - captureStartTime < CAPTURE_WARMUP_MS) continue

                // Convert to float samples for AEC
                val floatSamples = ShortArray(read).also { System.arraycopy(buffer, 0, it, 0, read) }
                    .map { it.toFloat() / Short.MAX_VALUE }.toFloatArray()

                // Resample to AEC rate (48kHz) for echo cancellation
                val aecSamples = resample(floatSamples, captureSampleRate, AEC_SAMPLE_RATE)

                // Apply echo cancellation
                val ecSamples = aecBridge?.processCapture(aecSamples) ?: aecSamples

                // Resample to target rate (24kHz) for transmission
                val targetSamples = resample(ecSamples, AEC_SAMPLE_RATE, TARGET_SAMPLE_RATE)

                // Encode as PCM16 base64
                val pcm16 = encodePcm16(targetSamples)
                val base64Data = Base64.encodeToString(pcm16, Base64.NO_WRAP)

                // Send to server
                try {
                    appModel.rpc.threadRealtimeAppendAudio(
                        threadKey.serverId,
                        ThreadRealtimeAppendAudioParams(
                            threadId = threadKey.threadId,
                            audio = ThreadRealtimeAudioChunk(
                                data = base64Data,
                                sampleRate = TARGET_SAMPLE_RATE.toUInt(),
                                numChannels = 1u,
                                samplesPerChannel = targetSamples.size.toUInt(),
                            ),
                        ),
                    )
                } catch (_: Exception) {}
            }
        }
    }

    private fun prepareCommunicationAudio(manager: AudioManager) {
        if (previousAudioMode == null) {
            previousAudioMode = manager.mode
        }
        runCatching { manager.mode = AudioManager.MODE_IN_COMMUNICATION }
        runCatching { manager.isMicrophoneMute = false }
        val focusRequest = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
            .setAudioAttributes(
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
                    .build()
            )
            .build()
        audioFocusRequest = focusRequest
        manager.requestAudioFocus(focusRequest)
    }

    private fun configureOutputRoute(manager: AudioManager) {
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            val targetType = if (speakerEnabled) {
                AudioDeviceInfo.TYPE_BUILTIN_SPEAKER
            } else {
                AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            }
            val device = manager.availableCommunicationDevices.firstOrNull { it.type == targetType }
            if (device != null) {
                runCatching { manager.setCommunicationDevice(device) }
            }
        }
        @Suppress("DEPRECATION")
        runCatching { manager.isSpeakerphoneOn = speakerEnabled }
    }

    fun setSpeakerEnabled(enabled: Boolean) {
        speakerEnabled = enabled
        audioManager?.let { configureOutputRoute(it) }
    }

    private fun createRecorder(manager: AudioManager): RecorderConfig? {
        val preferredRate = manager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)
            ?.toIntOrNull()
        val candidateRates = listOfNotNull(
            preferredRate,
            AEC_SAMPLE_RATE,
            44100,
            32000,
            TARGET_SAMPLE_RATE,
            16000,
        ).distinct()

        for (rate in candidateRates) {
            val minBufferSize = AudioRecord.getMinBufferSize(
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
            )
            if (minBufferSize <= 0) {
                android.util.Log.w("VoiceRuntime", "Skipping unsupported capture rate=$rate minBufferSize=$minBufferSize")
                continue
            }

            val record = AudioRecord(
                MediaRecorder.AudioSource.MIC,
                rate,
                AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT,
                max(minBufferSize * 2, rate / 5),
            )
            if (record.state == AudioRecord.STATE_INITIALIZED) {
                android.util.Log.i("VoiceRuntime", "Initialized AudioRecord rate=$rate buffer=$minBufferSize")
                return RecorderConfig(
                    sampleRate = rate,
                    bufferSize = minBufferSize,
                    audioRecord = record,
                )
            }

            android.util.Log.w("VoiceRuntime", "AudioRecord init failed for rate=$rate state=${record.state}")
            runCatching { record.release() }
        }

        return null
    }

    private suspend fun abortRealtimeSession(
        appModel: AppModel,
        threadKey: ThreadKey,
        reason: String,
    ) {
        android.util.Log.e("VoiceRuntime", reason)
        try {
            appModel.rpc.threadRealtimeStop(
                threadKey.serverId,
                ThreadRealtimeStopParams(threadId = threadKey.threadId),
            )
        } catch (e: Exception) {
            android.util.Log.w("VoiceRuntime", "Failed to stop realtime after audio init failure: ${e.message}")
        } finally {
            cleanup()
        }
    }

    // ── Audio playback ───────────────────────────────────────────────────────

    private fun playOutputAudio(base64Audio: String, sampleRate: Int) {
        scope.launch(Dispatchers.IO) {
            try {
                // Decode base64 → PCM16 → float samples
                val pcmBytes = Base64.decode(base64Audio, Base64.DEFAULT)
                val floatSamples = decodePcm16(pcmBytes)

                // Compute output level
                val rms = computeRmsFloat(floatSamples)
                val scaledLevel = (rms * LEVEL_SCALE).coerceAtMost(1f)
                updateOutputLevel(scaledLevel)

                // Resample to AEC rate for echo cancellation training
                val aecSamples = resample(floatSamples, sampleRate, AEC_SAMPLE_RATE)
                aecBridge?.analyzeRender(aecSamples)

                // Write PCM16 to AudioTrack. Blocking writes avoid the repeated underruns
                // seen with tiny realtime chunks on some Android devices.
                val pcm16Samples = FloatArray(aecSamples.size).also { output ->
                    for (i in aecSamples.indices) output[i] = aecSamples[i].coerceIn(-1f, 1f)
                }
                val shortSamples = ShortArray(pcm16Samples.size)
                for (i in pcm16Samples.indices) {
                    shortSamples[i] = (pcm16Samples[i] * Short.MAX_VALUE).toInt().toShort()
                }
                val wrote = synchronized(playbackLock) {
                    val track = audioTrack ?: return@synchronized 0
                    if (track.state != AudioTrack.STATE_INITIALIZED) {
                        return@synchronized 0
                    }
                    track.write(shortSamples, 0, shortSamples.size, AudioTrack.WRITE_BLOCKING)
                }
                if (wrote < 0) {
                    android.util.Log.w("VoiceRuntime", "AudioTrack write failed code=$wrote")
                }
            } catch (_: Exception) {}
        }
    }

    // ── Event handling ───────────────────────────────────────────────────────

    private suspend fun startRealtimeSession(appModel: AppModel, threadKey: ThreadKey) {
        android.util.Log.i("VoiceRuntime", "Starting realtime session for ${threadKey.serverId}/${threadKey.threadId}")
        synchronized(sessionLock) {
            val active = _activeSession.value
            if (active?.threadKey == threadKey && sessionJob?.isActive == true) {
                android.util.Log.i("VoiceRuntime", "Realtime session already starting/active for ${threadKey.threadId}")
                return
            }
            if (sessionJob?.isActive == true || captureJob?.isActive == true || active != null) {
                cleanup()
            }
            _activeSession.value = VoiceSessionState(threadKey = threadKey)
        }

        try {
            // Subscribe BEFORE starting realtime — otherwise we miss the RealtimeStarted event
            android.util.Log.i("VoiceRuntime", "Subscribing to updates first...")
            val subscription = appModel.store.subscribeUpdates()

            // Start the event loop in background — it will block on nextUpdate()
            sessionJob = scope.launch(Dispatchers.Default) {
                android.util.Log.i("VoiceRuntime", "Event loop started, waiting for updates...")
                while (true) {
                    try {
                        val update = subscription.nextUpdate()
                        android.util.Log.d("VoiceRuntime", "Got update: ${update::class.simpleName}")
                        handleRealtimeUpdate(appModel, update)
                    } catch (e: Exception) {
                        android.util.Log.e("VoiceRuntime", "Event loop failed", e)
                        throw e
                    }
                }
            }

            // Give the event loop a moment to start consuming
            kotlinx.coroutines.delay(50)

            android.util.Log.i("VoiceRuntime", "Calling threadRealtimeStart...")
            _activeSession.value = VoiceSessionState(threadKey = threadKey)
            appModel.rpc.threadRealtimeStart(
                threadKey.serverId,
                ThreadRealtimeStartParams(
                    threadId = threadKey.threadId,
                    prompt = realtimePrompt(appModel),
                    sessionId = "litter-voice-${UUID.randomUUID().toString().lowercase()}",
                    clientControlledHandoff = true,
                    dynamicTools = buildDynamicToolSpecs(),
                ),
            )
            android.util.Log.i("VoiceRuntime", "threadRealtimeStart succeeded, creating HandoffManager")
            handoffManager = HandoffManager.create(threadKey.serverId)
        } catch (e: Exception) {
            android.util.Log.e("VoiceRuntime", "startRealtimeSession failed", e)
            _activeSession.value = _activeSession.value
        }
    }

    private suspend fun handleRealtimeUpdate(appModel: AppModel, update: AppStoreUpdateRecord) {
        when (update) {
            is AppStoreUpdateRecord.RealtimeStarted -> {
                android.util.Log.i("VoiceRuntime", "RealtimeStarted!")
                val threadKey = _activeSession.value?.threadKey ?: return
                startAudioCapture(appModel, threadKey)
            }

            is AppStoreUpdateRecord.VoiceSessionChanged -> {
                val session = _activeSession.value ?: return
                val voiceSession = appModel.snapshot.value?.voiceSession
                android.util.Log.i(
                    "VoiceRuntime",
                    "VoiceSessionChanged: active=${voiceSession?.activeThread != null} phase=${voiceSession?.phase} error=${voiceSession?.lastError}",
                )
                // VoiceSessionChanged while CONNECTING means the server accepted and session is live
                if (session.threadKey == voiceSession?.activeThread && !isCapturing) {
                    android.util.Log.i("VoiceRuntime", "Voice session active in snapshot, starting audio")
                    startAudioCapture(appModel, session.threadKey)
                }
            }

            is AppStoreUpdateRecord.RealtimeHandoffRequested -> {
                processHandoffActions(appModel)
            }

            is AppStoreUpdateRecord.RealtimeOutputAudioDelta -> {
                val audio = update.notification.audio
                playOutputAudio(audio.data, audio.sampleRate.toInt())
            }
            is AppStoreUpdateRecord.RealtimeError -> {
                android.util.Log.e(
                    "VoiceRuntime",
                    "RealtimeError thread=${update.key.threadId} message=${update.notification.message}",
                )
            }
            is AppStoreUpdateRecord.RealtimeClosed -> {
                android.util.Log.i(
                    "VoiceRuntime",
                    "RealtimeClosed thread=${update.key.threadId} reason=${update.notification.reason}",
                )
            }
            else -> {}
        }
    }

    // ── Handoff action dispatch ──────────────────────────────────────────────

    private suspend fun processHandoffActions(appModel: AppModel) {
        val hm = handoffManager ?: return
        val actions = hm.uniffiDrainActions()
        for (action in actions) {
            dispatchHandoffAction(appModel, action)
        }
    }

    private suspend fun dispatchHandoffAction(appModel: AppModel, action: uniffi.codex_mobile_client.HandoffAction) {
        when (action) {
            is uniffi.codex_mobile_client.HandoffAction.StartThread -> {
                try {
                    val config = AppThreadLaunchConfig()
                    val resp = appModel.rpc.threadStart(
                        action.targetServerId,
                        config.toThreadStartParams(action.cwd),
                    )
                    handoffManager?.uniffiReportThreadCreated(action.handoffId, action.targetServerId, resp.thread.id)
                } catch (e: Exception) {
                    handoffManager?.uniffiReportThreadFailed(action.handoffId, e.message ?: "Thread creation failed")
                }
            }

            is uniffi.codex_mobile_client.HandoffAction.SendTurn -> {
                try {
                    val payload = AppComposerPayload(text = action.transcript)
                    appModel.startTurn(
                        ThreadKey(serverId = action.targetServerId, threadId = action.threadId),
                        payload,
                    )
                    handoffManager?.uniffiReportTurnSent(action.handoffId, 0u)
                    val handoffKey = ThreadKey(serverId = action.targetServerId, threadId = action.threadId)
                    appModel.store.setVoiceHandoffThread(key = handoffKey)
                } catch (e: Exception) {
                    handoffManager?.uniffiReportTurnFailed(action.handoffId, e.message ?: "Turn failed")
                }
            }

            is uniffi.codex_mobile_client.HandoffAction.ResolveHandoff -> {
                try {
                    // Send the resolved text back to the voice thread via appendText
                    appModel.rpc.threadRealtimeAppendText(
                        action.voiceThreadKey.serverId,
                        uniffi.codex_mobile_client.ThreadRealtimeAppendTextParams(
                            threadId = action.voiceThreadKey.threadId,
                            text = action.text,
                        ),
                    )
                } catch (_: Exception) {}
            }

            is uniffi.codex_mobile_client.HandoffAction.FinalizeHandoff -> {
                handoffManager?.uniffiReportFinalized(action.handoffId)
                appModel.store.setVoiceHandoffThread(key = null)
            }

            is uniffi.codex_mobile_client.HandoffAction.Error -> {
                android.util.Log.e("VoiceRuntime", "Handoff error: ${action.message}")
            }

            else -> {}
        }
    }

    private fun realtimePrompt(appModel: AppModel): String {
        val remoteServers = appModel.snapshot.value?.servers
            ?.filter { !it.isLocal && it.isConnected }
            ?.map { "- \"${it.displayName}\" (${it.host})" }
            ?: emptyList()
        val serverLines = buildList {
            add("- \"local\" (this device)")
            addAll(remoteServers)
        }.joinToString("\n")
        return """
            You are Codex in a live voice conversation inside Litter. Keep responses short, spoken, and conversational. Avoid markdown and code formatting unless explicitly asked.

            Available servers:
            $serverLines
            When using the codex tool, you MUST specify the "server" parameter.
            IMPORTANT: To list servers, list sessions, or read session history, you MUST use server="local".
            The "local" server has special tools that can see sessions across ALL connected servers in one call.
            Remote servers do NOT have these tools - never ask a remote server to list sessions.
            Use a remote server name ONLY to run coding tasks, shell commands, or file operations on that machine.
        """.trimIndent()
    }

    private fun buildDynamicToolSpecs(): List<DynamicToolSpec> = listOf(
        DynamicToolSpec(
            name = "list_servers",
            description = "List all connected servers and their status.",
            inputSchema = jsonObject(emptyMap(), emptyList()),
            deferLoading = false,
        ),
        DynamicToolSpec(
            name = "list_sessions",
            description = "List recent sessions/threads on a specific server or all connected servers.",
            inputSchema = jsonObject(
                mapOf(
                    "server" to jsonStringSchema(
                        "Server name to query. Omit to query all connected servers.",
                    ),
                ),
                emptyList(),
            ),
            deferLoading = false,
        ),
        DynamicToolSpec(
            name = "read_session",
            description = "Read the full conversation history of a session on a specific server.",
            inputSchema = jsonObject(
                mapOf(
                    "server" to jsonStringSchema("Server name where the session lives."),
                    "session_id" to jsonStringSchema("The session/thread ID to read."),
                ),
                listOf("server", "session_id"),
            ),
            deferLoading = false,
        ),
        DynamicToolSpec(
            name = "run_on_server",
            description = "Run a prompt on a remote server. Creates or reuses a thread and waits for the turn to complete.",
            inputSchema = jsonObject(
                mapOf(
                    "server" to jsonStringSchema("Server name to run the prompt on."),
                    "prompt" to jsonStringSchema("The prompt to send."),
                ),
                listOf("server", "prompt"),
            ),
            deferLoading = false,
        ),
    )

    private fun jsonStringSchema(description: String): JsonValue =
        JsonValue(
            kind = JsonValueKind.OBJECT,
            boolValue = null,
            i64Value = null,
            u64Value = null,
            f64Value = null,
            stringValue = null,
            arrayItems = null,
            objectEntries = listOf(
                JsonObjectEntry("type", jsonString("string")),
                JsonObjectEntry("description", jsonString(description)),
            ),
        )

    private fun jsonObject(
        properties: Map<String, JsonValue>,
        required: List<String>,
    ): JsonValue {
        val objectEntries = mutableListOf(
            JsonObjectEntry("type", jsonString("object")),
            JsonObjectEntry(
                "properties",
                JsonValue(
                    kind = JsonValueKind.OBJECT,
                    boolValue = null,
                    i64Value = null,
                    u64Value = null,
                    f64Value = null,
                    stringValue = null,
                    arrayItems = null,
                    objectEntries = properties.map { (key, value) -> JsonObjectEntry(key, value) },
                ),
            ),
        )
        if (required.isNotEmpty()) {
            objectEntries += JsonObjectEntry(
                "required",
                JsonValue(
                    kind = JsonValueKind.ARRAY,
                    boolValue = null,
                    i64Value = null,
                    u64Value = null,
                    f64Value = null,
                    stringValue = null,
                    arrayItems = required.map(::jsonString),
                    objectEntries = null,
                ),
            )
        }
        return JsonValue(
            kind = JsonValueKind.OBJECT,
            boolValue = null,
            i64Value = null,
            u64Value = null,
            f64Value = null,
            stringValue = null,
            arrayItems = null,
            objectEntries = objectEntries,
        )
    }

    private fun jsonString(value: String): JsonValue =
        JsonValue(
            kind = JsonValueKind.STRING,
            boolValue = null,
            i64Value = null,
            u64Value = null,
            f64Value = null,
            stringValue = value,
            arrayItems = null,
            objectEntries = null,
        )

    // ── Level management with decay ──────────────────────────────────────────

    private fun updateInputLevel(level: Float) {
        val session = _activeSession.value ?: return
        _activeSession.value = session.copy(inputLevel = level)

        if (level > INPUT_THRESHOLD) {
            val token = UUID.randomUUID().toString()
            inputDecayToken = token
            scope.launch {
                delay(INPUT_DECAY_MS)
                if (inputDecayToken == token) {
                    _activeSession.value = _activeSession.value?.copy(inputLevel = 0f)
                }
            }
        }
    }

    private fun updateOutputLevel(level: Float) {
        val session = _activeSession.value ?: return
        _activeSession.value = session.copy(outputLevel = level)

        if (level > OUTPUT_THRESHOLD) {
            val token = UUID.randomUUID().toString()
            outputDecayToken = token
            scope.launch {
                delay(OUTPUT_DECAY_MS)
                if (outputDecayToken == token) {
                    _activeSession.value = _activeSession.value?.copy(
                        outputLevel = 0f,
                    )
                }
            }
        }
    }

    // ── Audio utilities ──────────────────────────────────────────────────────

    private fun computeRms(buffer: ShortArray, size: Int): Float {
        var sum = 0.0
        for (i in 0 until size) {
            val s = buffer[i].toDouble() / Short.MAX_VALUE
            sum += s * s
        }
        return sqrt(sum / size).toFloat()
    }

    private fun computeRmsFloat(buffer: FloatArray): Float {
        var sum = 0.0
        for (s in buffer) { sum += s * s }
        return sqrt(sum / buffer.size).toFloat()
    }

    private fun resample(input: FloatArray, fromRate: Int, toRate: Int): FloatArray {
        if (fromRate == toRate) return input
        val ratio = fromRate.toDouble() / toRate
        val outSize = (input.size / ratio).toInt()
        val output = FloatArray(outSize)
        for (i in 0 until outSize) {
            val pos = i * ratio
            val idx = pos.toInt().coerceAtMost(input.size - 1)
            val frac = (pos - idx).toFloat()
            val s0 = input[idx]
            val s1 = input[(idx + 1).coerceAtMost(input.size - 1)]
            output[i] = s0 + frac * (s1 - s0)
        }
        return output
    }

    private fun encodePcm16(samples: FloatArray): ByteArray {
        val buf = ByteBuffer.allocate(samples.size * 2).order(ByteOrder.LITTLE_ENDIAN)
        for (s in samples) {
            buf.putShort((s.coerceIn(-1f, 1f) * Short.MAX_VALUE).toInt().toShort())
        }
        return buf.array()
    }

    private fun decodePcm16(pcmBytes: ByteArray): FloatArray {
        val buf = ByteBuffer.wrap(pcmBytes).order(ByteOrder.LITTLE_ENDIAN)
        val samples = FloatArray(pcmBytes.size / 2)
        for (i in samples.indices) {
            samples[i] = buf.getShort().toFloat() / Short.MAX_VALUE
        }
        return samples
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    private fun cleanup() {
        synchronized(captureLock) {
            isCapturing = false
            captureJob?.cancel()
            captureJob = null
            try { audioRecord?.stop() } catch (_: Exception) {}
            try { audioRecord?.release() } catch (_: Exception) {}
            audioRecord = null
        }
        sessionJob?.cancel()
        sessionJob = null
        synchronized(playbackLock) {
            try { audioTrack?.stop() } catch (_: Exception) {}
            try { audioTrack?.release() } catch (_: Exception) {}
            audioTrack = null
        }
        aecBridge?.release()
        aecBridge = null
        audioFocusRequest?.let { request ->
            runCatching { audioManager?.abandonAudioFocusRequest(request) }
        }
        audioFocusRequest = null
        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.S) {
            runCatching { audioManager?.clearCommunicationDevice() }
        }
        @Suppress("DEPRECATION")
        runCatching { audioManager?.isSpeakerphoneOn = false }
        previousAudioMode?.let { mode ->
            runCatching { audioManager?.mode = mode }
        }
        previousAudioMode = null
        audioManager = null
        handoffManager = null
        inputDecayToken = null
        outputDecayToken = null
        captureSampleRate = TARGET_SAMPLE_RATE
        _activeSession.value = null
    }
}
