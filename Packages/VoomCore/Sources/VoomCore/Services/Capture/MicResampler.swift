import Foundation
@preconcurrency import AVFoundation

/// Normalises microphone PCM to mono at 48 kHz before it is mixed with system
/// audio.
///
/// The mic tap runs at the device's native format, which is not 48 kHz mono for
/// a lot of real hardware — a Bluetooth headset on HFP reports 16 kHz, plenty of
/// interfaces report 44.1 kHz, and many mics are multi-channel. Appending those
/// samples straight into a 48 kHz mix plays them back at the wrong rate, so the
/// speaker sounds sped up or slowed down and pitch-shifted.
///
/// One instance per recording: the converter keeps resampler state across
/// buffers, which is what stops a click at every buffer boundary.
/// Adapted from PR #3 by @vitaliiznak.
public final class MicResampler: @unchecked Sendable {
    public static let targetSampleRate: Double = 48_000

    private var converter: AVAudioConverter?
    private var converterSourceRate: Double = 0

    public init() {}

    /// Interleaved input at `channels`/`sampleRate` → mono 48 kHz.
    ///
    /// Returns the input unchanged when it is already mono at the target rate,
    /// and an empty array when the input is unusable — callers should treat that
    /// as "nothing to mix" rather than as silence to pad with.
    public func monoAt48k(_ samples: [Float], channels: Int, sampleRate: Double) -> [Float] {
        guard channels > 0, sampleRate > 0, !samples.isEmpty else { return [] }
        let frames = samples.count / channels
        guard frames > 0 else { return [] }

        // Downmix first: converting one channel instead of N is both cheaper and
        // avoids depending on the converter's channel-mapping defaults.
        let mono: [Float]
        if channels == 1 {
            mono = Array(samples.prefix(frames))
        } else {
            var downmixed = [Float](repeating: 0, count: frames)
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels {
                    sum += samples[frame * channels + channel]
                }
                downmixed[frame] = sum * scale
            }
            mono = downmixed
        }

        if abs(sampleRate - Self.targetSampleRate) < 0.5 { return mono }
        return resample(mono, from: sampleRate)
    }

    private func resample(_ mono: [Float], from sampleRate: Double) -> [Float] {
        guard let sourceFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                  channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32, sampleRate: Self.targetSampleRate,
                  channels: 1, interleaved: false)
        else { return mono }

        // Rebuild only when the device's rate actually changes — a fresh
        // converter per buffer would discard the resampler's tail each time.
        if converter == nil || converterSourceRate != sampleRate {
            converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
            converterSourceRate = sampleRate
        }
        guard let converter else { return mono }

        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(mono.count)),
              let inputChannel = input.floatChannelData?[0] else { return mono }
        mono.withUnsafeBufferPointer { source in
            inputChannel.update(from: source.baseAddress!, count: mono.count)
        }
        input.frameLength = AVAudioFrameCount(mono.count)

        // Round the capacity up: a 16 kHz → 48 kHz buffer produces strictly more
        // frames than it consumes, and a short buffer truncates audio.
        let ratio = Self.targetSampleRate / sampleRate
        let capacity = AVAudioFrameCount((Double(mono.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return mono }

        // The input block is invoked synchronously by `convert`, but the
        // compiler can't see that — a reference box keeps the one-shot flag
        // without an unsafe capture of a local var.
        let pending = PendingInput(buffer: input)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            guard let next = pending.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return next
        }

        guard status != .error, conversionError == nil,
              output.frameLength > 0, let outputChannel = output.floatChannelData?[0] else {
            return mono
        }
        return Array(UnsafeBufferPointer(start: outputChannel, count: Int(output.frameLength)))
    }
}

/// One-shot holder for the buffer handed to `AVAudioConverter`'s input block.
private final class PendingInput: @unchecked Sendable {
    private var buffer: AVAudioPCMBuffer?
    init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    func take() -> AVAudioPCMBuffer? {
        defer { buffer = nil }
        return buffer
    }
}
