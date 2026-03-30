import AVFoundation
import Foundation

enum VoiceSessionAudioCodec {
    static let targetSampleRate: Double = 24_000
    static let aecProcessingSampleRate: Double = 48_000
    static let targetChannels: Int = 1

    static func makeInputChunk(buffer: AVAudioPCMBuffer) -> AppRealtimeAudioChunk? {
        guard let samples = resampleToTarget(buffer: buffer) else { return nil }
        return encodeChunk(samples: samples)
    }

    static func makeInputChunk(samples: [Float], sampleRate: Double, channels: Int) -> AppRealtimeAudioChunk? {
        guard !samples.isEmpty else { return nil }
        let resampled = resample(samples: samples, from: sampleRate, to: targetSampleRate)
        guard !resampled.isEmpty else { return nil }
        return encodeChunk(samples: resampled, channels: channels)
    }

    static func makePlaybackBuffer(from chunk: AppRealtimeAudioChunk) -> AVAudioPCMBuffer? {
        guard let samples = decodePCM16Base64(chunk.data, numChannels: Int(chunk.numChannels)) else {
            return nil
        }
        return makePlaybackBuffer(samples: samples, sampleRate: Double(chunk.sampleRate))
    }

    static func resampleToTarget(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let samples = monoSamples(from: buffer) else { return nil }
        let resampled = resample(samples: samples, from: buffer.format.sampleRate, to: targetSampleRate)
        return resampled.isEmpty ? nil : resampled
    }

    static func resampleForAec(buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let samples = monoSamples(from: buffer) else { return nil }
        let resampled = resample(samples: samples, from: buffer.format.sampleRate, to: aecProcessingSampleRate)
        return resampled.isEmpty ? nil : resampled
    }

    static func resampleForAec(samples: [Float], sampleRate: Double) -> [Float] {
        resample(samples: samples, from: sampleRate, to: aecProcessingSampleRate)
    }

    static func resampleToTarget(samples: [Float], sampleRate: Double) -> [Float] {
        resample(samples: samples, from: sampleRate, to: targetSampleRate)
    }

    static func resampleToTarget(
        samples: [Float],
        sampleRate: Double,
        targetSampleRate: Double
    ) -> [Float] {
        resample(samples: samples, from: sampleRate, to: targetSampleRate)
    }

    static func encodeChunk(samples: [Float], channels: Int = targetChannels) -> AppRealtimeAudioChunk {
        let data = encodePCM16(samples: samples)
        return AppRealtimeAudioChunk(
            data: data.base64EncodedString(),
            sampleRate: UInt32(targetSampleRate.rounded()),
            numChannels: UInt32(channels),
            samplesPerChannel: UInt32(samples.count),
            itemId: nil
        )
    }

    static func makePlaybackBuffer(
        samples: [Float],
        sampleRate: Double,
        channels: AVAudioChannelCount = 1
    ) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: channels
        )
        guard let format,
              let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(samples.count)
              ) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let floatChannelData = buffer.floatChannelData else { return nil }
        let channelCount = Int(format.channelCount)
        for channelIndex in 0..<channelCount {
            let channelData = floatChannelData[channelIndex]
            for (index, sample) in samples.enumerated() {
                channelData[index] = sample
            }
        }
        return buffer
    }

    static func decodePCM16Base64(_ base64: String, numChannels: Int) -> [Float]? {
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        let samplesPerFrame = max(numChannels, 1)
        let rawCount = data.count / MemoryLayout<Int16>.size
        guard rawCount >= samplesPerFrame else { return nil }

        let int16Samples: [Int16] = data.withUnsafeBytes { rawBuffer in
            Array(rawBuffer.bindMemory(to: Int16.self))
        }
        let frameCount = int16Samples.count / samplesPerFrame
        guard frameCount > 0 else { return nil }

        if samplesPerFrame == 1 {
            return int16Samples.map { Float($0) / Float(Int16.max) }
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for frameIndex in 0..<frameCount {
            var accumulator: Float = 0
            for channelIndex in 0..<samplesPerFrame {
                accumulator += Float(int16Samples[(frameIndex * samplesPerFrame) + channelIndex])
                    / Float(Int16.max)
            }
            mono[frameIndex] = accumulator / Float(samplesPerFrame)
        }
        return mono
    }

    static func encodePCM16(samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * MemoryLayout<Int16>.size)
        for sample in samples {
            var value = Int16(max(-1, min(1, sample)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func rmsLevel(buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = monoSamples(from: buffer) else { return 0 }
        return rmsLevel(samples: samples)
    }

    static func rmsLevel(samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(Float.zero) { partial, sample in
            partial + (sample * sample)
        } / Float(samples.count)
        return min(sqrtf(meanSquare) * 3, 1)
    }

    private static func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else { return nil }

        if channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        var mono = [Float](repeating: 0, count: frameCount)
        for channelIndex in 0..<channelCount {
            let channel = UnsafeBufferPointer(start: channelData[channelIndex], count: frameCount)
            for sampleIndex in 0..<frameCount {
                mono[sampleIndex] += channel[sampleIndex]
            }
        }
        let divisor = Float(channelCount)
        for sampleIndex in 0..<frameCount {
            mono[sampleIndex] /= divisor
        }
        return mono
    }

    private static func resample(samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty else { return [] }
        guard abs(sourceRate - targetRate) >= 0.5 else { return samples }

        let ratio = targetRate / sourceRate
        let outputCount = max(Int((Double(samples.count) * ratio).rounded(.toNearestOrAwayFromZero)), 1)
        guard outputCount > 1 else { return [samples[0]] }

        var output = [Float](repeating: 0, count: outputCount)
        for outputIndex in 0..<outputCount {
            let sourcePosition = Double(outputIndex) / ratio
            let lowerIndex = min(Int(sourcePosition.rounded(.down)), samples.count - 1)
            let upperIndex = min(lowerIndex + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lowerIndex))
            let lower = samples[lowerIndex]
            let upper = samples[upperIndex]
            output[outputIndex] = lower + ((upper - lower) * fraction)
        }
        return output
    }
}
