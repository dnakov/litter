import AVFoundation
import Foundation

@MainActor
final class VoiceSessionCoordinator {
    enum Event {
        case inputLevel(Float)
        case outputLevel(Float)
        case routeChanged(VoiceSessionAudioRoute)
        case interrupted
        case failure(String)
    }

    private actor AudioUploadPump {
        private let send: @Sendable (AppRealtimeAudioChunk) async -> Void
        private var queue: [AppRealtimeAudioChunk] = []
        private var draining = false

        init(send: @escaping @Sendable (AppRealtimeAudioChunk) async -> Void) {
            self.send = send
        }

        func enqueue(_ chunk: AppRealtimeAudioChunk) async {
            queue.append(chunk)
            guard !draining else { return }
            draining = true
            while !queue.isEmpty {
                let next = queue.removeFirst()
                await send(next)
            }
            draining = false
        }
    }

    private final class CaptureWarmupState {
        private let lock = NSLock()
        private var captureSuppressedUntil: CFAbsoluteTime = 0
        private var sessionStartTime: CFAbsoluteTime = 0

        func start(at time: CFAbsoluteTime) {
            lock.lock()
            captureSuppressedUntil = time + 0.35
            sessionStartTime = time
            lock.unlock()
        }

        func reset() {
            lock.lock()
            captureSuppressedUntil = 0
            sessionStartTime = 0
            lock.unlock()
        }

        func shouldSuppressCaptureUpload(at time: CFAbsoluteTime) -> Bool {
            lock.lock()
            let suppressed = time < captureSuppressedUntil
            lock.unlock()
            return suppressed
        }

        func refreshStartupCaptureSuppressionForOutput(at time: CFAbsoluteTime) {
            lock.lock()
            defer { lock.unlock() }
            guard sessionStartTime > 0,
                  time - sessionStartTime < 5.0 else {
                return
            }
            captureSuppressedUntil = max(captureSuppressedUntil, time + 0.4)
        }
    }

    var onEvent: ((Event) -> Void)?

    private let session = AVAudioSession.sharedInstance()
    private var audioEngine: AVAudioEngine?
    private var playerNode: AVAudioPlayerNode?
    private var playbackFormat: AVAudioFormat?
    private var uploadPump: AudioUploadPump?
    private var notificationObservers: [NSObjectProtocol] = []
    private var aecBridge: AecBridge?
    private var speakerModeEnabled = true
    private let captureWarmupState = CaptureWarmupState()

    var isRunning: Bool {
        audioEngine != nil
    }

    func start(sendAudio: @escaping @Sendable (AppRealtimeAudioChunk) async -> Void) throws {
        stop()

        try applyAudioSessionCategory()
        try session.setActive(true)

        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let mixerFormat = engine.mainMixerNode.outputFormat(forBus: 0)
        let playerFormat = AVAudioFormat(
            standardFormatWithSampleRate: mixerFormat.sampleRate,
            channels: max(mixerFormat.channelCount, 1)
        )
        guard let playerFormat else {
            throw NSError(
                domain: "Litter",
                code: 3201,
                userInfo: [NSLocalizedDescriptionKey: "Failed to configure voice output format"]
            )
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playerFormat)

        let inputNode = engine.inputNode
        let outputNode = engine.outputNode
        do {
            try inputNode.setVoiceProcessingEnabled(true)
            try outputNode.setVoiceProcessingEnabled(true)
        } catch {
            LLog.error("voice", "voice processing unavailable", error: error)
        }
        let aecBridge = AecBridge(sampleRate: UInt32(VoiceSessionAudioCodec.aecProcessingSampleRate))
        self.aecBridge = aecBridge
        let inputFormat = inputNode.outputFormat(forBus: 0)
        let uploadPump = AudioUploadPump(send: sendAudio)
        self.uploadPump = uploadPump
        let startTime = CFAbsoluteTimeGetCurrent()
        captureWarmupState.start(at: startTime)

        inputNode.installTap(onBus: 0, bufferSize: 480, format: inputFormat) { [weak self, aecBridge, captureWarmupState] buffer, _ in
            let inputLevel = VoiceSessionAudioCodec.rmsLevel(buffer: buffer)
            guard let self else { return }
            if let aecSamples = VoiceSessionAudioCodec.resampleForAec(buffer: buffer) {
                let processedSamples = aecBridge?.processCapture(aecSamples) ?? aecSamples
                guard !processedSamples.isEmpty else {
                    Task { @MainActor [weak self] in
                        self?.onEvent?(.inputLevel(inputLevel))
                    }
                    return
                }

                guard !captureWarmupState.shouldSuppressCaptureUpload(at: CFAbsoluteTimeGetCurrent()) else {
                    Task { @MainActor [weak self] in
                        self?.onEvent?(.inputLevel(0))
                    }
                    return
                }

                let outputSamples = VoiceSessionAudioCodec.resampleToTarget(
                    samples: processedSamples,
                    sampleRate: VoiceSessionAudioCodec.aecProcessingSampleRate
                )
                let chunk = VoiceSessionAudioCodec.encodeChunk(samples: outputSamples)
                Task { await uploadPump.enqueue(chunk) }
            }
            Task { @MainActor [weak self] in
                self?.onEvent?(.inputLevel(inputLevel))
            }
        }

        do {
            try engine.start()
            player.play()
        } catch {
            inputNode.removeTap(onBus: 0)
            throw error
        }

        audioEngine = engine
        playerNode = player
        playbackFormat = playerFormat
        installAudioNotifications()
        emitRoute()
    }

    func stop() {
        clearAudioNotifications()
        uploadPump = nil
        aecBridge = nil

        if let inputNode = audioEngine?.inputNode {
            inputNode.removeTap(onBus: 0)
        }
        playerNode?.stop()
        audioEngine?.stop()
        playerNode = nil
        audioEngine = nil
        playbackFormat = nil
        speakerModeEnabled = true
        captureWarmupState.reset()

        try? session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    func enqueueOutputAudio(_ chunk: AppRealtimeAudioChunk) {
        guard let playerNode,
              let engine = audioEngine,
              let playbackFormat,
              let samples = VoiceSessionAudioCodec.decodePCM16Base64(
                chunk.data,
                numChannels: Int(chunk.numChannels)
              ) else {
            return
        }
        captureWarmupState.refreshStartupCaptureSuppressionForOutput(at: CFAbsoluteTimeGetCurrent())
        let aecSamples = VoiceSessionAudioCodec.resampleForAec(
            samples: samples,
            sampleRate: Double(chunk.sampleRate)
        )
        aecBridge?.analyzeRender(aecSamples)
        let playbackSamples = VoiceSessionAudioCodec.resampleToTarget(
            samples: samples,
            sampleRate: Double(chunk.sampleRate),
            targetSampleRate: playbackFormat.sampleRate
        )
        guard let buffer = VoiceSessionAudioCodec.makePlaybackBuffer(
            samples: playbackSamples,
            sampleRate: playbackFormat.sampleRate,
            channels: playbackFormat.channelCount
        ) else {
            return
        }
        let outputLevel = VoiceSessionAudioCodec.rmsLevel(samples: samples)

        if !engine.isRunning {
            LLog.warn("voice", "engine not running during enqueue, restarting")
            do {
                try applyAudioSessionCategory()
                try session.setActive(true)
                try engine.start()
            } catch {
                LLog.error("voice", "failed to restart engine", error: error)
                onEvent?(.failure("Failed to restart audio output"))
                return
            }
        }

        playerNode.scheduleBuffer(buffer, completionHandler: nil)
        if !playerNode.isPlaying {
            playerNode.play()
        }
        onEvent?(.outputLevel(outputLevel))
    }

    func flushPlayback() {
        playerNode?.stop()
        onEvent?(.outputLevel(0))
    }

    func toggleSpeaker() throws {
        let route = currentRoute()
        guard route.supportsSpeakerToggle else { return }
        speakerModeEnabled.toggle()
        try applyAudioSessionCategory()
        try session.setActive(true)
        emitRoute()
    }

    private func applyAudioSessionCategory() throws {
        var options: AVAudioSession.CategoryOptions = [.mixWithOthers, .allowBluetooth]
        if speakerModeEnabled {
            options.insert(.defaultToSpeaker)
        }

        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: options
        )
        try session.setPreferredIOBufferDuration(0.005)
    }

    private func installAudioNotifications() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.emitRoute()
            },
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                self?.handleInterruption(notification)
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                self?.onEvent?(.failure("Audio services reset"))
            }
        ]
    }

    private func clearAudioNotifications() {
        let center = NotificationCenter.default
        for observer in notificationObservers {
            center.removeObserver(observer)
        }
        notificationObservers = []
    }

    private func handleInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else {
            return
        }

        switch type {
        case .began:
            onEvent?(.interrupted)
        case .ended:
            do {
                try applyAudioSessionCategory()
                try session.setActive(true)
                if let engine = audioEngine, !engine.isRunning {
                    try engine.start()
                }
                if let playerNode, !playerNode.isPlaying {
                    playerNode.play()
                }
                emitRoute()
            } catch {
                onEvent?(.failure("Failed to resume audio session"))
            }
        @unknown default:
            break
        }
    }

    private func emitRoute() {
        onEvent?(.routeChanged(currentRoute()))
    }

    private func currentRoute() -> VoiceSessionAudioRoute {
        let output = session.currentRoute.outputs.first
        let name = output?.portName.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallbackName = (name?.isEmpty == false ? name! : "Audio")

        switch output?.portType {
        case .builtInSpeaker:
            return .speaker
        case .builtInReceiver:
            return .receiver
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE:
            return .bluetooth(fallbackName)
        case .headphones, .headsetMic, .usbAudio:
            return .headphones(fallbackName)
        case .carAudio:
            return .carPlay(fallbackName)
        case .airPlay:
            return .airPlay(fallbackName)
        default:
            return .unknown(fallbackName)
        }
    }
}
