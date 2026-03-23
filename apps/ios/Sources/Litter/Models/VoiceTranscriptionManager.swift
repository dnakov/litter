import AVFoundation
import Observation

@MainActor
@Observable
final class VoiceTranscriptionManager {
    var isRecording = false
    var isTranscribing = false
    var audioLevel: Float = 0
    var error: String?

    @ObservationIgnored private var audioEngine: AVAudioEngine?
    @ObservationIgnored private let bufferCollector = AudioBufferCollector()
    @ObservationIgnored private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0

    private static let targetSampleRate: Double = 24000
    private static let transcribeModel = "gpt-4o-mini-transcribe"

    func requestMicPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    func startRecording() {
        bufferCollector.reset()
        error = nil

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, options: .defaultToSpeaker)
            try session.setActive(true)
        } catch {
            self.error = "Failed to configure audio session."
            return
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let collector = bufferCollector

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            collector.append(buffer)
            guard let self else { return }
            let now = CFAbsoluteTimeGetCurrent()
            guard now - self.lastLevelUpdate > 0.05 else { return }
            self.lastLevelUpdate = now
            let level = Self.rms(buffer: buffer)
            Task { @MainActor in self.audioLevel = level }
        }

        do {
            try engine.start()
        } catch {
            self.error = "Failed to start audio engine."
            return
        }

        audioEngine = engine
        isRecording = true
    }

    func stopAndTranscribe(authMethod: AuthMode?, authToken: String?) async -> String? {
        guard isRecording else { return nil }
        teardownEngine()

        guard let wav = encodeWAV() else {
            error = "Failed to encode audio."
            return nil
        }

        guard let authToken, !authToken.isEmpty else {
            error = "Not logged in."
            return nil
        }

        isTranscribing = true
        defer { isTranscribing = false }

        do {
            return try await transcribe(wav: wav, authMethod: authMethod, token: authToken)
        } catch let err {
            self.error = err.localizedDescription
            return nil
        }
    }

    func cancelRecording() {
        teardownEngine()
    }

    // MARK: - Private

    private func teardownEngine() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        isRecording = false
        audioLevel = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func encodeWAV() -> Data? {
        let buffers = bufferCollector.drain()
        guard let first = buffers.first else { return nil }

        let srcRate = first.format.sampleRate
        let targetRate = Self.targetSampleRate

        var allSamples = [Float]()
        for buf in buffers {
            guard let data = buf.floatChannelData?[0] else { continue }
            allSamples.append(contentsOf: UnsafeBufferPointer(start: data, count: Int(buf.frameLength)))
        }
        guard !allSamples.isEmpty else { return nil }

        let resampled: [Int16]
        if abs(srcRate - targetRate) < 1.0 {
            resampled = allSamples.map { Self.floatToInt16($0) }
        } else {
            let ratio = targetRate / srcRate
            let outCount = Int(Double(allSamples.count) * ratio)
            var out = [Int16](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let srcIdx = Double(i) / ratio
                let idx = Int(srcIdx)
                let frac = Float(srcIdx - Double(idx))
                let s0 = allSamples[min(idx, allSamples.count - 1)]
                let s1 = allSamples[min(idx + 1, allSamples.count - 1)]
                out[i] = Self.floatToInt16(s0 + frac * (s1 - s0))
            }
            resampled = out
        }

        guard Float(resampled.count) / Float(targetRate) >= 0.5 else { return nil }

        let dataSize = resampled.count * 2
        var wav = Data(capacity: 44 + dataSize)
        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLE(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLE(UInt32(16))
        wav.appendLE(UInt16(1)) // PCM
        wav.appendLE(UInt16(1)) // mono
        wav.appendLE(UInt32(UInt32(targetRate)))
        wav.appendLE(UInt32(UInt32(targetRate) * 2)) // byte rate
        wav.appendLE(UInt16(2)) // block align
        wav.appendLE(UInt16(16)) // bits per sample
        wav.append(contentsOf: "data".utf8)
        wav.appendLE(UInt32(dataSize))
        resampled.withUnsafeBufferPointer { ptr in
            wav.append(contentsOf: UnsafeRawBufferPointer(ptr))
        }
        return wav
    }

    private func transcribe(wav: Data, authMethod: AuthMode?, token: String) async throws -> String {
        let isChatGPT = authMethod == .chatgpt || authMethod == .chatgptAuthTokens

        let url: URL
        if isChatGPT {
            url = URL(string: "https://chatgpt.com/backend-api/transcribe")!
        } else {
            url = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wav)
        body.append("\r\n".data(using: .utf8)!)
        if !isChatGPT {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"model\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(Self.transcribeModel)\r\n".data(using: .utf8)!)
        }
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw NSError(domain: "Transcription", code: status, userInfo: [
                NSLocalizedDescriptionKey: "Transcription failed (\(status))"
            ])
        }

        struct TranscriptionResponse: Decodable { let text: String }
        return try JSONDecoder().decode(TranscriptionResponse.self, from: data).text
    }

    private static func floatToInt16(_ v: Float) -> Int16 {
        Int16(max(-1, min(1, v)) * Float(Int16.max))
    }

    private static func rms(buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<count { sum += data[i] * data[i] }
        return min(sqrtf(sum / Float(count)) * 3, 1.0)
    }
}

private final class AudioBufferCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        buffers.append(buffer)
        lock.unlock()
    }

    func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        let result = buffers
        buffers = []
        lock.unlock()
        return result
    }

    func reset() {
        lock.lock()
        buffers = []
        lock.unlock()
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
