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
import uniffi.codex_mobile_client.AppDynamicToolSpec
import uniffi.codex_mobile_client.AppStoreUpdateRecord
import uniffi.codex_mobile_client.HandoffManager
import uniffi.codex_mobile_client.PinnedThreadKey
import uniffi.codex_mobile_client.ThreadKey
import uniffi.codex_mobile_client.AppAppendRealtimeAudioRequest
import uniffi.codex_mobile_client.AppFinalizeRealtimeHandoffRequest
import uniffi.codex_mobile_client.AppResolveRealtimeHandoffRequest
import uniffi.codex_mobile_client.AppStartRealtimeSessionRequest
import uniffi.codex_mobile_client.AppStopRealtimeSessionRequest
import uniffi.codex_mobile_client.AppRealtimeAudioChunk
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
        private const val LOCAL_SERVER_ID = "local"
        private const val VOICE_PREFS_NAME = "litter.voice"
        private const val PERSISTED_LOCAL_VOICE_THREAD_ID_KEY = "litter.voice.local.thread_id"
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
    private var stopRequestedThreadKey: ThreadKey? = null

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

    suspend fun preparePinnedLocalVoiceThread(
        appModel: AppModel,
        cwd: String,
        model: String? = null,
    ): ThreadKey? = ensurePinnedLocalVoiceThread(appModel, cwd = cwd, model = model)

    suspend fun startPinnedLocalVoiceCall(
        appModel: AppModel, cwd: String, model: String? = null, effort: String? = null,
    ): ThreadKey? {
        val threadKey = preparePinnedLocalVoiceThread(appModel, cwd = cwd, model = model) ?: return null
        startRealtimeSession(appModel, threadKey)
        return threadKey
    }

    suspend fun startVoiceOnThread(appModel: AppModel, key: ThreadKey) {
        startRealtimeSession(appModel, key)
    }

    suspend fun stopActiveVoiceSession(appModel: AppModel) {
        val session = _activeSession.value ?: return
        val key = session.threadKey
        synchronized(sessionLock) {
            if (stopRequestedThreadKey == key) {
                return
            }
            stopRequestedThreadKey = key
        }
        cleanup(clearStopRequest = false)
        try {
            appModel.client.stopRealtimeSession(
                key.serverId,
                AppStopRealtimeSessionRequest(threadId = key.threadId),
            )
        } catch (_: Exception) {}
        synchronized(sessionLock) {
            if (stopRequestedThreadKey == key) {
                stopRequestedThreadKey = null
            }
        }
    }

    suspend fun stopVoiceSessionIfActive(appModel: AppModel, threadKey: ThreadKey) {
        val shouldStop = synchronized(sessionLock) {
            _activeSession.value?.threadKey == threadKey || stopRequestedThreadKey == threadKey
        }
        if (shouldStop) {
            stopActiveVoiceSession(appModel)
        }
    }

    fun clearPinnedLocalVoiceThreadIfMatches(appModel: AppModel, threadKey: ThreadKey) {
        val persistedThreadId = persistedLocalVoiceThreadId(appModel) ?: return
        if (threadKey.serverId == LOCAL_SERVER_ID && threadKey.threadId == persistedThreadId) {
            setPersistedLocalVoiceThreadId(appModel, null)
        }
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

        if (manager.mode != AudioManager.MODE_IN_COMMUNICATION) {
            android.util.Log.w(
                "VoiceRuntime",
                "AudioManager mode not set to MODE_IN_COMMUNICATION after prepare (mode=${manager.mode}), retrying",
            )
            runCatching { manager.mode = AudioManager.MODE_IN_COMMUNICATION }
        }

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
            while (shouldContinueCapturing(threadKey)) {
                val read = recorder.read(buffer, 0, buffer.size)
                if (read <= 0) continue
                if (!shouldContinueCapturing(threadKey)) break

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
                if (!shouldContinueCapturing(threadKey)) break
                try {
                    appModel.client.appendRealtimeAudio(
                        threadKey.serverId,
                        AppAppendRealtimeAudioRequest(
                            threadId = threadKey.threadId,
                            audio = AppRealtimeAudioChunk(
                                data = base64Data,
                                sampleRate = TARGET_SAMPLE_RATE.toUInt(),
                                numChannels = 1u,
                                samplesPerChannel = targetSamples.size.toUInt(),
                                itemId = null,
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
            // Prefer Bluetooth SCO (HFP) over A2DP for voice communication
            val btScoDevice = manager.availableCommunicationDevices.firstOrNull {
                it.type == AudioDeviceInfo.TYPE_BLUETOOTH_SCO
            }
            if (btScoDevice != null && !speakerEnabled) {
                runCatching { manager.setCommunicationDevice(btScoDevice) }
            } else {
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
        }
        @Suppress("DEPRECATION")
        runCatching { manager.isSpeakerphoneOn = speakerEnabled }
    }

    fun isSpeakerEnabled(): Boolean = speakerEnabled

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
            appModel.client.stopRealtimeSession(
                threadKey.serverId,
                AppStopRealtimeSessionRequest(threadId = threadKey.threadId),
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

    suspend fun retryActiveSession(appModel: AppModel) {
        val session = _activeSession.value ?: return
        val threadKey = session.threadKey
        android.util.Log.i("VoiceRuntime", "Retrying active session for ${threadKey.threadId}")
        cleanup()
        startRealtimeSession(appModel, threadKey)
    }

    private suspend fun startRealtimeSession(appModel: AppModel, threadKey: ThreadKey) {
        // Check RECORD_AUDIO permission before anything else
        val hasPermission = android.content.pm.PackageManager.PERMISSION_GRANTED ==
            appModel.appContext.checkSelfPermission(android.Manifest.permission.RECORD_AUDIO)
        if (!hasPermission) {
            android.util.Log.e("VoiceRuntime", "RECORD_AUDIO permission not granted, cannot start voice session")
            return
        }

        val resolvedThreadKey = appModel.ensureThreadLoaded(threadKey) ?: threadKey
        val hasKnownThread = appModel.snapshot.value?.threads?.any { it.key == resolvedThreadKey } == true
        if (!hasKnownThread) {
            android.util.Log.w(
                "VoiceRuntime",
                "Refusing to start realtime for missing thread ${resolvedThreadKey.serverId}/${resolvedThreadKey.threadId}",
            )
            return
        }

        android.util.Log.i(
            "VoiceRuntime",
            "Starting realtime session for ${resolvedThreadKey.serverId}/${resolvedThreadKey.threadId}",
        )
        synchronized(sessionLock) {
            val active = _activeSession.value
            if (active?.threadKey == resolvedThreadKey && sessionJob?.isActive == true) {
                android.util.Log.i("VoiceRuntime", "Realtime session already starting/active for ${resolvedThreadKey.threadId}")
                return
            }
            if (sessionJob?.isActive == true || captureJob?.isActive == true || active != null) {
                cleanup()
            }
            _activeSession.value = VoiceSessionState(threadKey = resolvedThreadKey)
        }

        try {
            cleanupKnownRealtimeVoiceSessions(appModel, keepThreadKey = resolvedThreadKey)

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
            _activeSession.value = VoiceSessionState(threadKey = resolvedThreadKey)
            appModel.client.startRealtimeSession(
                resolvedThreadKey.serverId,
                AppStartRealtimeSessionRequest(
                    threadId = resolvedThreadKey.threadId,
                    prompt = realtimePrompt(appModel),
                    sessionId = "litter-voice-${UUID.randomUUID().toString().lowercase()}",
                    clientControlledHandoff = true,
                    dynamicTools = buildDynamicToolSpecs(),
                ),
            )
            android.util.Log.i("VoiceRuntime", "threadRealtimeStart succeeded, creating HandoffManager")
            handoffManager = HandoffManager.create(resolvedThreadKey.serverId)
        } catch (e: Exception) {
            android.util.Log.e("VoiceRuntime", "startRealtimeSession failed", e)
            cleanup()
        }
    }

    private suspend fun ensurePinnedLocalVoiceThread(
        appModel: AppModel,
        cwd: String,
        model: String? = null,
    ): ThreadKey? {
        val serverId = ensureLocalServerConnected(appModel) ?: return null
        val launchConfig = appModel.launchState.launchConfig(modelOverride = model)

        persistedLocalVoiceThreadId(appModel)?.let { storedThreadId ->
            val key = ThreadKey(serverId = serverId, threadId = storedThreadId)
            val knownThread = appModel.snapshot.value?.let { snapshot ->
                snapshot.threads.any { it.key == key } || snapshot.sessionSummaries.any { it.key == key }
            } == true

            if (knownThread) {
                appModel.store.setActiveThread(key)
                return key
            }

            val loadedKey = appModel.ensureThreadLoaded(key)
            if (loadedKey != null) {
                appModel.store.setActiveThread(loadedKey)
                setPersistedLocalVoiceThreadId(appModel, loadedKey.threadId)
                appModel.refreshSnapshot()
                return loadedKey
            }

            setPersistedLocalVoiceThreadId(appModel, null)
        }

        return try {
            val key = appModel.client.startThread(
                serverId,
                launchConfig.toAppStartThreadRequest(
                    preferredVoiceThreadCwd(appModel, key = null, fallback = cwd),
                ),
            )
            SavedThreadsStore.add(
                appModel.appContext,
                PinnedThreadKey(serverId = key.serverId, threadId = key.threadId),
            )
            appModel.store.setActiveThread(key)
            setPersistedLocalVoiceThreadId(appModel, key.threadId)
            appModel.refreshSnapshot()
            key
        } catch (_: Exception) {
            null
        }
    }

    private suspend fun ensureLocalServerConnected(appModel: AppModel): String? {
        appModel.snapshot.value?.servers?.firstOrNull { it.isLocal && it.isConnected }?.let { server ->
            return server.serverId
        }

        val currentLocal = appModel.snapshot.value?.servers?.firstOrNull { it.isLocal }
        val serverId = currentLocal?.serverId ?: LOCAL_SERVER_ID
        val displayName = currentLocal?.displayName ?: "Local"
        return try {
            appModel.serverBridge.connectLocalServer(serverId, displayName, "127.0.0.1", 0u)
            appModel.restoreStoredLocalChatGptAuth(serverId)
            appModel.refreshSnapshot()
            serverId
        } catch (_: Exception) {
            null
        }
    }

    private suspend fun cleanupKnownRealtimeVoiceSessions(
        appModel: AppModel,
        keepThreadKey: ThreadKey? = null,
    ) {
        val candidates = linkedSetOf<ThreadKey>()
        _activeSession.value?.threadKey
            ?.takeIf { it.threadId.isNotBlank() }
            ?.let(candidates::add)
        persistedLocalVoiceThreadId(appModel)
            ?.takeIf { it.isNotBlank() }
            ?.let { candidates.add(ThreadKey(serverId = LOCAL_SERVER_ID, threadId = it)) }

        for (candidate in candidates) {
            if (candidate == keepThreadKey) continue
            runCatching {
                appModel.client.stopRealtimeSession(
                    candidate.serverId,
                    AppStopRealtimeSessionRequest(threadId = candidate.threadId),
                )
            }
        }
    }

    private suspend fun handleRealtimeUpdate(appModel: AppModel, update: AppStoreUpdateRecord) {
        when (update) {
            is AppStoreUpdateRecord.RealtimeStarted -> {
                android.util.Log.i("VoiceRuntime", "RealtimeStarted!")
                val threadKey = _activeSession.value?.threadKey ?: return
                if (update.key != threadKey || isStopRequested(threadKey)) return
                startAudioCapture(appModel, threadKey)
            }

            is AppStoreUpdateRecord.FullResync -> {
                // After a lagged resync we may have missed RealtimeStarted.
                // Refresh the Kotlin snapshot from Rust, then check if voice is live.
                val session = _activeSession.value ?: return
                appModel.refreshSnapshot()
                val voiceSession = appModel.snapshot.value?.voiceSession
                android.util.Log.i("VoiceRuntime", "FullResync: activeThread=${voiceSession?.activeThread} isCapturing=$isCapturing")
                if (session.threadKey == voiceSession?.activeThread &&
                    !isCapturing &&
                    !isStopRequested(session.threadKey)
                ) {
                    android.util.Log.i("VoiceRuntime", "FullResync: voice session already active, starting audio capture")
                    startAudioCapture(appModel, session.threadKey)
                }
            }

            is AppStoreUpdateRecord.VoiceSessionChanged -> {
                val session = _activeSession.value ?: return
                val voiceSession = appModel.snapshot.value?.voiceSession
                android.util.Log.i(
                    "VoiceRuntime",
                    "VoiceSessionChanged: active=${voiceSession?.activeThread != null} phase=${voiceSession?.phase} error=${voiceSession?.lastError}",
                )
                // VoiceSessionChanged while CONNECTING means the server accepted and session is live
                if (session.threadKey == voiceSession?.activeThread &&
                    !isCapturing &&
                    !isStopRequested(session.threadKey)
                ) {
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
                if (!matchesCurrentSession(update.key)) return
                android.util.Log.e(
                    "VoiceRuntime",
                    "RealtimeError thread=${update.key.threadId} message=${update.notification.message}",
                )
                if (!update.notification.message.contains("active response in progress", ignoreCase = true)) {
                    cleanupForThread(update.key)
                }
            }
            is AppStoreUpdateRecord.RealtimeClosed -> {
                if (!matchesCurrentSession(update.key)) return
                android.util.Log.i(
                    "VoiceRuntime",
                    "RealtimeClosed thread=${update.key.threadId} reason=${update.notification.reason}",
                )
                cleanupForThread(update.key)
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
                    val key = appModel.client.startThread(
                        action.targetServerId,
                        appModel.launchState.threadStartRequest(action.cwd),
                    )
                    SavedThreadsStore.add(
                        appModel.appContext,
                        PinnedThreadKey(serverId = key.serverId, threadId = key.threadId),
                    )
                    handoffManager?.uniffiReportThreadCreated(action.handoffId, action.targetServerId, key.threadId)
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
                    appModel.client.resolveRealtimeHandoff(
                        action.voiceThreadKey.serverId,
                        AppResolveRealtimeHandoffRequest(
                            threadId = action.voiceThreadKey.threadId,
                            toolCallOutput = action.text,
                        ),
                    )
                } catch (_: Exception) {}
            }

            is uniffi.codex_mobile_client.HandoffAction.FinalizeHandoff -> {
                try {
                    appModel.client.finalizeRealtimeHandoff(
                        action.voiceThreadKey.serverId,
                        AppFinalizeRealtimeHandoffRequest(
                            threadId = action.voiceThreadKey.threadId,
                        ),
                    )
                } catch (_: Exception) {}
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
            IMPORTANT: Use the local discovery tools for server and session lookup.
            The "local" server has special tools that can see sessions across ALL connected servers in one call.
            After calling list_servers or list_sessions, always give the user a short spoken summary of what you found. Do not stop after the tool result alone.
            Remote servers do NOT have these tools - never ask a remote server to list sessions.
            Use a remote server name ONLY to run coding tasks, shell commands, or file operations on that machine.
        """.trimIndent()
    }

    private fun buildDynamicToolSpecs(): List<AppDynamicToolSpec> = listOf(
        AppDynamicToolSpec(
            name = "list_servers",
            description = "List all connected servers and their status. After calling this tool, briefly tell the user what you found.",
            inputSchemaJson = """{"type":"object","properties":{}}""",
            deferLoading = false,
        ),
        AppDynamicToolSpec(
            name = "list_sessions",
            description = "List recent sessions/threads on a specific server or all connected servers. After calling this tool, briefly tell the user what you found.",
            inputSchemaJson = """{"type":"object","properties":{"server":{"type":"string","description":"Server name to query. Omit to query all connected servers."}}}""",
            deferLoading = false,
        ),
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

    private fun persistedLocalVoiceThreadId(appModel: AppModel): String? {
        val stored = voicePrefs(appModel)
            .getString(PERSISTED_LOCAL_VOICE_THREAD_ID_KEY, null)
            ?.trim()
            .orEmpty()
        return stored.ifEmpty { null }
    }

    private fun setPersistedLocalVoiceThreadId(appModel: AppModel, threadId: String?) {
        val trimmed = threadId?.trim().orEmpty()
        val editor = voicePrefs(appModel).edit()
        if (trimmed.isEmpty()) {
            editor.remove(PERSISTED_LOCAL_VOICE_THREAD_ID_KEY)
        } else {
            editor.putString(PERSISTED_LOCAL_VOICE_THREAD_ID_KEY, trimmed)
        }
        editor.apply()
    }

    private fun voicePrefs(appModel: AppModel) =
        appModel.appContext.getSharedPreferences(VOICE_PREFS_NAME, Context.MODE_PRIVATE)

    private fun preferredVoiceThreadCwd(
        appModel: AppModel,
        key: ThreadKey?,
        fallback: String,
    ): String {
        val existingCwd = key
            ?.let { threadKey ->
                appModel.snapshot.value
                    ?.threads
                    ?.firstOrNull { it.key == threadKey }
                    ?.info
                    ?.cwd
                    ?.trim()
            }
            .orEmpty()
        if (existingCwd.isNotEmpty()) {
            return existingCwd
        }

        val trimmedFallback = fallback.trim()
        if (trimmedFallback.isNotEmpty()) {
            return trimmedFallback
        }

        return appModel.launchState.snapshot.value.currentCwd.trim().ifEmpty { "/" }
    }

    // ── Cleanup ──────────────────────────────────────────────────────────────

    private fun shouldContinueCapturing(threadKey: ThreadKey): Boolean {
        val isSessionCurrent = synchronized(sessionLock) {
            _activeSession.value?.threadKey == threadKey && stopRequestedThreadKey != threadKey
        }
        val captureActive = synchronized(captureLock) {
            isCapturing
        }
        return isSessionCurrent && captureActive
    }

    private fun isStopRequested(threadKey: ThreadKey): Boolean =
        synchronized(sessionLock) { stopRequestedThreadKey == threadKey }

    private fun matchesCurrentSession(threadKey: ThreadKey): Boolean =
        synchronized(sessionLock) {
            _activeSession.value?.threadKey == threadKey || stopRequestedThreadKey == threadKey
        }

    private fun cleanupForThread(threadKey: ThreadKey, clearStopRequest: Boolean = true) {
        if (!matchesCurrentSession(threadKey)) return
        cleanup(clearStopRequest = clearStopRequest)
    }

    private fun cleanup(clearStopRequest: Boolean = true) {
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
        if (clearStopRequest) {
            synchronized(sessionLock) {
                stopRequestedThreadKey = null
            }
        }
        _activeSession.value = null
    }
}
