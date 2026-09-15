@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import Synchronization

public enum MicPCM {
    public static let targetSampleRate: Double = 48_000

    public static func mono48k(
        floats: UnsafePointer<Float>,
        floatCount: Int,
        channels: Int,
        sampleRate: Double,
        gain: Float = 1
    ) -> [Float] {
        resample(downmix(floats: floats, floatCount: floatCount, channels: channels, gain: gain),
                 from: sampleRate, to: targetSampleRate)
    }

    fileprivate static func downmix(
        floats: UnsafePointer<Float>,
        floatCount: Int,
        channels: Int,
        gain: Float = 1
    ) -> [Float] {
        let channelCount = max(channels, 1)
        let frameCount = floatCount / channelCount
        guard frameCount > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            for i in 0..<frameCount {
                mono[i] = clamp(floats[i] * gain)
            }
        } else {
            let inv = 1 / Float(channelCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += floats[frame * channelCount + channel]
                }
                mono[frame] = clamp(sum * inv * gain)
            }
        }

        return mono
    }

    public static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0 else { return samples }
        if abs(sourceRate - targetRate) < 0.5 { return samples }

        let ratio = targetRate / sourceRate
        let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
        var output = [Float](repeating: 0, count: outCount)
        let lastIndex = samples.count - 1
        for i in 0..<outCount {
            let src = Double(i) / ratio
            let left = Int(src)
            if left >= lastIndex {
                output[i] = samples[lastIndex]
                continue
            }
            let frac = Float(src - Double(left))
            output[i] = samples[left] * (1 - frac) + samples[left + 1] * frac
        }
        return output
    }

    private static func clamp(_ value: Float) -> Float {
        min(max(value, -1), 1)
    }
}

/// Retains the resampler's history across capture callbacks. Native conversion preserves
/// the headset's upper speech band and avoids repeated samples at buffer boundaries.
final class MicPCMConverter {
    private var converter: AVAudioConverter?

    func mono48k(floats: [Float], channels: Int, sampleRate: Double) -> [Float]? {
        guard sampleRate.isFinite, sampleRate > 0, channels > 0, !floats.isEmpty else { return nil }
        let mono = floats.withUnsafeBufferPointer { buffer in
            MicPCM.downmix(floats: buffer.baseAddress!, floatCount: floats.count, channels: channels)
        }
        guard !mono.isEmpty else { return nil }
        if sampleRate == MicPCM.targetSampleRate {
            converter = nil
            return mono
        }

        if converter?.inputFormat.sampleRate != sampleRate {
            guard let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
            ), let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32, sampleRate: MicPCM.targetSampleRate, channels: 1, interleaved: false
            ), let newConverter = AVAudioConverter(from: inputFormat, to: outputFormat) else { return nil }
            newConverter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            // A live stream has no samples before recording begins.
            newConverter.primeMethod = .none
            converter = newConverter
        }
        guard let converter,
              let input = AVAudioPCMBuffer(pcmFormat: converter.inputFormat, frameCapacity: AVAudioFrameCount(mono.count))
        else { return nil }
        input.frameLength = AVAudioFrameCount(mono.count)
        mono.withUnsafeBufferPointer { buffer in
            input.floatChannelData![0].update(from: buffer.baseAddress!, count: mono.count)
        }

        let capacity = AVAudioFrameCount(ceil(Double(mono.count) * MicPCM.targetSampleRate / sampleRate)) + 512
        guard let output = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity) else { return nil }
        let supplied = Mutex(false)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            let needsInput = supplied.withLock { value in
                guard !value else { return false }
                value = true
                return true
            }
            guard needsInput else {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil else { return nil }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

final class MicTapConverter: @unchecked Sendable {
    private let beautifier: VoiceBeautifier?
    private let lock = NSLock()
    private var frameCursor: Int64 = 0

    init(enhanceVoice: Bool = false, headset: Bool = false) {
        self.beautifier = enhanceVoice
            ? VoiceBeautifier(sampleRate: MicPCM.targetSampleRate, headset: headset)
            : nil
    }

    func convert(buffer: AVAudioPCMBuffer, time _: AVAudioTime) -> CMSampleBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard let floats = Self.interleavedFloats(from: buffer), !floats.isEmpty else { return nil }
        var mono = floats.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return [Float]() }
            return MicPCM.mono48k(
                floats: base,
                floatCount: floats.count,
                channels: Int(buffer.format.channelCount),
                sampleRate: buffer.format.sampleRate
            )
        }
        guard !mono.isEmpty else { return nil }
        beautifier?.process(&mono)

        let pts = CMTime(value: frameCursor, timescale: CMTimeScale(MicPCM.targetSampleRate))
        frameCursor += Int64(mono.count)
        return MicPCM.sampleBuffer(
            floats: mono,
            sampleRate: MicPCM.targetSampleRate,
            presentationTime: pts
        )
    }

    private static func interleavedFloats(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        guard frameCount > 0, channels > 0, let channelData = buffer.floatChannelData else { return nil }

        if channels == 1 {
            return Array(UnsafeBufferPointer(start: channelData[0], count: frameCount))
        }

        var interleaved = [Float](repeating: 0, count: frameCount * channels)
        for frame in 0..<frameCount {
            for channel in 0..<channels {
                interleaved[frame * channels + channel] = channelData[channel][frame]
            }
        }
        return interleaved
    }
}
