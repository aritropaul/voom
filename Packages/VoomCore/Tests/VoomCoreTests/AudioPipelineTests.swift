import Testing
import AVFoundation
import CoreMedia
@testable import VoomCore

/// Covers the two audio-correctness fixes taken from PR #3: per-sample timing
/// preservation when retiming, and normalising mic PCM before it is mixed.
struct AudioSampleTimingTests {

    /// A 1024-frame buffer at 48 kHz, built the way the mic tap builds them —
    /// one timing entry whose duration describes a single sample.
    private func makeBuffer(frames: Int, sampleRate: Int32, startSeconds: Double) -> CMSampleBuffer? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
        )
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        let byteCount = frames * 4
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block
        ) == noErr, let block else { return nil }
        var silence = [Float](repeating: 0, count: frames)
        _ = silence.withUnsafeMutableBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: byteCount)
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(seconds: startSeconds, preferredTimescale: sampleRate),
            decodeTimeStamp: .invalid
        )
        var size = 4
        var buffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
            sampleCount: CMItemCount(frames), sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &buffer
        ) == noErr else { return nil }
        return buffer
    }

    @Test func retimingMovesThePresentationTimeToTheTarget() throws {
        let buffer = try #require(makeBuffer(frames: 1024, sampleRate: 48_000, startSeconds: 12.5))
        let target = CMTime(seconds: 3.0, preferredTimescale: 48_000)
        let retimed = try #require(AudioSampleTiming.retime(buffer, to: target))
        #expect(CMSampleBufferGetPresentationTimeStamp(retimed).seconds == 3.0)
    }

    @Test func retimingLeavesPerSampleDurationAlone() throws {
        // The bug this replaces wrote the buffer's TOTAL duration into the single
        // timing entry, which describes one sample — inflating the buffer's span
        // by the frame count. Per-sample duration must stay at 1/48000.
        let buffer = try #require(makeBuffer(frames: 1024, sampleRate: 48_000, startSeconds: 0))
        let retimed = try #require(AudioSampleTiming.retime(buffer, to: CMTime(seconds: 5, preferredTimescale: 48_000)))

        var timing = CMSampleTimingInfo()
        #expect(CMSampleBufferGetSampleTimingInfo(retimed, at: 0, timingInfoOut: &timing) == noErr)
        #expect(timing.duration == CMTime(value: 1, timescale: 48_000))

        // And the buffer's overall duration still covers exactly 1024 samples.
        let total = CMSampleBufferGetDuration(retimed)
        #expect(abs(total.seconds - 1024.0 / 48_000.0) < 1e-9)
    }

    @Test func sampleCountSurvivesRetiming() throws {
        let buffer = try #require(makeBuffer(frames: 512, sampleRate: 48_000, startSeconds: 1))
        let retimed = try #require(AudioSampleTiming.retime(buffer, to: .zero))
        #expect(CMSampleBufferGetNumSamples(retimed) == 512)
    }

    @Test func consecutiveBuffersStayGapFree() throws {
        // Two adjacent 1024-frame buffers retimed onto a zero-based clock must
        // remain adjacent — a wrong per-sample duration shows up here as a gap.
        let frameDuration = 1024.0 / 48_000.0
        let first = try #require(makeBuffer(frames: 1024, sampleRate: 48_000, startSeconds: 100))
        let second = try #require(makeBuffer(frames: 1024, sampleRate: 48_000, startSeconds: 100 + frameDuration))

        let a = try #require(AudioSampleTiming.retime(first, to: .zero))
        let b = try #require(AudioSampleTiming.retime(second, to: CMTime(seconds: frameDuration, preferredTimescale: 48_000)))

        let endOfA = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(a), CMSampleBufferGetDuration(a))
        let startOfB = CMSampleBufferGetPresentationTimeStamp(b)
        #expect(abs(endOfA.seconds - startOfB.seconds) < 1e-6)
    }
}

struct MicResamplerTests {

    @Test func alreadyMonoAt48kPassesThroughUnchanged() {
        let input: [Float] = [0.1, -0.2, 0.3, -0.4]
        let output = MicResampler().monoAt48k(input, channels: 1, sampleRate: 48_000)
        #expect(output == input)
    }

    @Test func stereoIsAveragedDownToMono() {
        // Interleaved L,R pairs → the mean of each pair.
        let input: [Float] = [1.0, 0.0, 0.5, 0.5, -1.0, 1.0]
        let output = MicResampler().monoAt48k(input, channels: 2, sampleRate: 48_000)
        #expect(output.count == 3)
        #expect(abs(output[0] - 0.5) < 1e-6)
        #expect(abs(output[1] - 0.5) < 1e-6)
        #expect(abs(output[2] - 0.0) < 1e-6)
    }

    @Test func aBluetoothRateIsResampledUpToFortyEightKilohertz() {
        // 16 kHz HFP is the case that made the mic play back sped up: without
        // resampling, 1600 frames get mixed as if they were 1/30 s of 48 kHz
        // audio instead of 1/10 s.
        let input = (0..<1_600).map { sinf(2 * .pi * 220 * Float($0) / 16_000) }
        let output = MicResampler().monoAt48k(input, channels: 1, sampleRate: 16_000)
        #expect(output.count > 0)
        // 0.1 s of audio at 48 kHz ≈ 4800 frames; allow converter latency slack.
        #expect(abs(Double(output.count) - 4_800) < 400, "got \(output.count) frames")
    }

    @Test func aDownwardRateIsResampledToo() {
        let input = (0..<4_410).map { sinf(2 * .pi * 440 * Float($0) / 44_100) }
        let output = MicResampler().monoAt48k(input, channels: 1, sampleRate: 44_100)
        // 0.1 s → ~4800 frames at 48 kHz.
        #expect(abs(Double(output.count) - 4_800) < 400, "got \(output.count) frames")
    }

    @Test func resampledAudioKeepsItsEnergy() {
        // A pure tone must survive the rate change — a broken conversion shows up
        // as silence or as a wildly different amplitude.
        let input = (0..<1_600).map { sinf(2 * .pi * 220 * Float($0) / 16_000) }
        let output = MicResampler().monoAt48k(input, channels: 1, sampleRate: 16_000)
        let inputPeak = input.map(abs).max() ?? 0
        let outputPeak = output.map(abs).max() ?? 0
        #expect(outputPeak > inputPeak * 0.5)
        #expect(outputPeak < inputPeak * 1.5)
    }

    @Test func streamingBuffersReuseOneConverter() {
        // State continuity across buffers is the reason the resampler is an
        // instance and not a static: five chunks should total roughly the same
        // as one chunk of the combined length, not five converter warm-ups.
        let resampler = MicResampler()
        var total = 0
        for _ in 0..<5 {
            let chunk = (0..<1_600).map { sinf(2 * .pi * 220 * Float($0) / 16_000) }
            total += resampler.monoAt48k(chunk, channels: 1, sampleRate: 16_000).count
        }
        #expect(abs(Double(total) - 24_000) < 600, "got \(total) frames")
    }

    @Test func degenerateInputIsRejectedRatherThanGuessedAt() {
        let resampler = MicResampler()
        #expect(resampler.monoAt48k([], channels: 1, sampleRate: 48_000).isEmpty)
        #expect(resampler.monoAt48k([0.1, 0.2], channels: 0, sampleRate: 48_000).isEmpty)
        #expect(resampler.monoAt48k([0.1, 0.2], channels: 1, sampleRate: 0).isEmpty)
        // Fewer samples than one full frame.
        #expect(resampler.monoAt48k([0.1], channels: 4, sampleRate: 48_000).isEmpty)
    }
}
