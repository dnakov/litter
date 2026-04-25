#if targetEnvironment(macCatalyst)
import AVFoundation
import Foundation

/// Mac-side 19 kHz sine emitter for ultrasonic Doppler ranging. Most adults
/// can't hear above ~17 kHz; 19 kHz is comfortably inaudible while still
/// well below typical laptop speaker rolloff (~21 kHz). The iPhone reader
/// detects the carrier and computes velocity from frequency shift.
///
/// Buffer length is chosen so 19 kHz completes an integer number of cycles
/// over the loop window: 4800 samples at 48 kHz = 100 ms = 1900 cycles
/// exactly, so the looped buffer has no per-cycle click.
@MainActor
final class UltrasonicEmitter {
    /// Emitted carrier frequency in Hz. Pairs with `UltrasonicReader`'s
    /// search band (18.5–19.5 kHz). Don't change one without the other.
    static let carrierFrequencyHz: Double = 19_000

    private static let sampleRate: Double = 48_000
    /// 100 ms buffer → 1900 full cycles of 19 kHz at 48 kHz sample rate
    /// (gcd(19000, 48000) = 1000 → minimum seamless period = 48 samples).
    private static let bufferLength: AVAudioFrameCount = 4800
    /// Output amplitude (0–1). Loud enough for an iPhone mic at ~3 m, quiet
    /// enough that frequency-leakage harmonics into the audible band stay
    /// imperceptible.
    private static let amplitude: Float = 0.15

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var isRunning = false

    func start() {
        guard !isRunning else { return }
        let format = AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: 1
        )!
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: Self.bufferLength
        ) else {
            LLog.warn("pair", "ultrasonic: failed to allocate output buffer")
            return
        }
        buffer.frameLength = Self.bufferLength

        let channel = buffer.floatChannelData![0]
        let twoPi = 2.0 * Double.pi
        for i in 0..<Int(Self.bufferLength) {
            let phase = twoPi * Double(i) * Self.carrierFrequencyHz / Self.sampleRate
            channel[i] = Float(sin(phase)) * Self.amplitude
        }

        engine.attach(player)
        engine.connect(player, to: engine.outputNode, format: format)

        do {
            try engine.start()
            player.scheduleBuffer(buffer, at: nil, options: .loops, completionHandler: nil)
            player.play()
            isRunning = true
            LLog.info(
                "pair",
                "ultrasonic emitter started",
                fields: ["freq_hz": Int(Self.carrierFrequencyHz)]
            )
        } catch {
            LLog.error("pair", "ultrasonic emitter start failed", error: error)
        }
    }

    func stop() {
        guard isRunning else { return }
        player.stop()
        engine.stop()
        engine.detach(player)
        isRunning = false
    }
}
#endif
