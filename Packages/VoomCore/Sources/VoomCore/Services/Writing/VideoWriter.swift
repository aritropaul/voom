import Foundation
import AVFoundation
import CoreVideo

public final class VideoWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voom.videowriter", qos: .userInteractive)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var audioInput: AVAssetWriterInput?
    private var secondAudioInput: AVAssetWriterInput?
    private var isSessionStarted = false
    private var lastVideoTime: CMTime = .zero

    // Audio mixing state
    private var hasBothAudioSources = false
    private var pendingMicFloats: [Float] = []
    private var audioTrackMode: AudioTrackMode = .mixed

    // Audio gain multipliers
    private let systemAudioGainSolo: Float = 0.2
    private let micAudioGainSolo: Float = 6.0
    private let systemAudioGainMixed: Float = 0.05
    private let micAudioGainMixed: Float = 4.5

    public init() {}

    public func configure(
        outputURL: URL,
        width: Int,
        height: Int,
        hasSystemAudio: Bool,
        hasMicAudio: Bool,
        preset: VideoQualityPreset = .screenRecording,
        audioMode: AudioTrackMode = .mixed
    ) throws {
        self.audioTrackMode = audioMode
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video input - HEVC (H.265) with hardware acceleration on Apple Silicon
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: preset.bitRate,
                AVVideoExpectedSourceFrameRateKey: preset.fps,
                AVVideoMaxKeyFrameIntervalKey: preset.gopLength,
                AVVideoAllowFrameReorderingKey: preset.enableBFrames
            ]
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true

        let sourcePixelBufferAttributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height
        ]
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: sourcePixelBufferAttributes
        )

        writer.add(videoInput)
        self.videoInput = videoInput
        self.pixelBufferAdaptor = adaptor

        if audioMode == .separate && hasSystemAudio && hasMicAudio {
            // Separate tracks: system audio stereo + mic mono
            let systemSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            let sysInput = AVAssetWriterInput(mediaType: .audio, outputSettings: systemSettings)
            sysInput.expectsMediaDataInRealTime = true
            writer.add(sysInput)
            self.audioInput = sysInput

            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micInput.expectsMediaDataInRealTime = true
            writer.add(micInput)
            self.secondAudioInput = micInput

            self.hasBothAudioSources = true
        } else {
            // Single audio track — system audio is stereo, mic-only is mono.
            // When both are active, mic samples are mixed into the system audio stream.
            if hasSystemAudio || hasMicAudio {
                let channelCount = hasSystemAudio ? 2 : 1
                let bitRate = hasSystemAudio ? 192000 : 128000
                let audioSettings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48000,
                    AVNumberOfChannelsKey: channelCount,
                    AVEncoderBitRateKey: bitRate
                ]
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                writer.add(input)
                self.audioInput = input
                self.hasBothAudioSources = hasSystemAudio && hasMicAudio
            }
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.assetWriter = writer
        self.isSessionStarted = true
    }

    public func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        queue.async { [self] in
            guard let adaptor = pixelBufferAdaptor,
                  let input = videoInput,
                  input.isReadyForMoreMediaData,
                  isSessionStarted else { return }

            guard time > lastVideoTime || lastVideoTime == .zero else { return }

            adaptor.append(pixelBuffer, withPresentationTime: time)
            lastVideoTime = time
        }
    }

    public func appendSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [self] in
            guard let input = audioInput,
                  input.isReadyForMoreMediaData,
                  isSessionStarted else { return }

            if audioTrackMode == .separate {
                // Write system audio directly to its own track
                let boosted = Self.applyGain(to: buffer, gain: systemAudioGainSolo)
                input.append(boosted ?? buffer)
            } else if hasBothAudioSources {
                let mixed = mixMicIntoSystem(buffer)
                input.append(mixed ?? buffer)
            } else {
                let boosted = Self.applyGain(to: buffer, gain: systemAudioGainSolo)
                input.append(boosted ?? buffer)
            }
        }
    }

    public func appendMicAudioSample(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [self] in
            if audioTrackMode == .separate {
                // Write mic audio directly to its own track
                guard let input = secondAudioInput,
                      input.isReadyForMoreMediaData,
                      isSessionStarted else { return }
                let boosted = Self.applyGain(to: buffer, gain: micAudioGainSolo)
                input.append(boosted ?? buffer)
            } else if hasBothAudioSources {
                bufferMicSamples(buffer)
            } else {
                // Mic only — write directly
                guard let input = audioInput,
                      input.isReadyForMoreMediaData,
                      isSessionStarted else { return }
                let boosted = Self.applyGain(to: buffer, gain: micAudioGainSolo)
                input.append(boosted ?? buffer)
            }
        }
    }

    public func finalize() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let writer = assetWriter else {
                    continuation.resume()
                    return
                }

                videoInput?.markAsFinished()
                audioInput?.markAsFinished()
                secondAudioInput?.markAsFinished()

                writer.finishWriting {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.pixelBufferAdaptor = nil
                    self.audioInput = nil
                    self.secondAudioInput = nil
                    self.isSessionStarted = false
                    self.lastVideoTime = .zero
                    self.hasBothAudioSources = false
                    self.pendingMicFloats = []
                    self.audioTrackMode = .mixed
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Audio Mixing

    /// Buffer mic PCM samples (mono) with gain applied for later mixing.
    private func bufferMicSamples(_ sampleBuffer: CMSampleBuffer) {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let data = dataPointer else { return }

        if asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            let count = length / MemoryLayout<Float>.size
            data.withMemoryRebound(to: Float.self, capacity: count) { ptr in
                for i in 0..<count {
                    pendingMicFloats.append(min(max(ptr[i] * micAudioGainMixed, -1.0), 1.0))
                }
            }
        } else if asbd.pointee.mBitsPerChannel == 16 {
            let count = length / MemoryLayout<Int16>.size
            data.withMemoryRebound(to: Int16.self, capacity: count) { ptr in
                for i in 0..<count {
                    let f = Float(ptr[i]) / Float(Int16.max) * micAudioGainMixed
                    pendingMicFloats.append(min(max(f, -1.0), 1.0))
                }
            }
        }

        // Cap buffer at ~1 second to prevent unbounded growth
        let maxSize = 48000
        if pendingMicFloats.count > maxSize {
            pendingMicFloats.removeFirst(pendingMicFloats.count - maxSize)
        }
    }

    /// Mix buffered mic samples into a system audio sample buffer.
    private func mixMicIntoSystem(_ systemBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(systemBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              asbd.pointee.mFormatID == kAudioFormatLinearPCM,
              asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              let blockBuffer = CMSampleBufferGetDataBuffer(systemBuffer) else {
            return Self.applyGain(to: systemBuffer, gain: systemAudioGainMixed)
        }

        let channels = Int(asbd.pointee.mChannelsPerFrame)
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length, dataPointerOut: &dataPointer) == noErr,
              let data = dataPointer else {
            return Self.applyGain(to: systemBuffer, gain: systemAudioGainMixed)
        }

        let floatCount = length / MemoryLayout<Float>.size
        let frameCount = floatCount / max(channels, 1)

        // Create mutable copy of audio data
        var mutableBlock: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: length, flags: 0,
            blockBufferOut: &mutableBlock
        ) == noErr, let newBlock = mutableBlock,
              CMBlockBufferReplaceDataBytes(
                with: data, blockBuffer: newBlock,
                offsetIntoDestination: 0, dataLength: length
              ) == noErr else {
            return Self.applyGain(to: systemBuffer, gain: systemAudioGainMixed)
        }

        var newDataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(newBlock, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: nil, dataPointerOut: &newDataPointer) == noErr,
              let newData = newDataPointer else {
            return Self.applyGain(to: systemBuffer, gain: systemAudioGainMixed)
        }

        let floatPtr = newData.withMemoryRebound(to: Float.self, capacity: floatCount) { $0 }
        let isNonInterleaved = asbd.pointee.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0

        // Apply system gain
        for i in 0..<floatCount {
            floatPtr[i] *= systemAudioGainMixed
        }

        // Mix in pending mic samples (mono → both channels)
        let micSamplesToMix = min(frameCount, pendingMicFloats.count)
        if micSamplesToMix > 0 {
            if isNonInterleaved {
                let framesPerPlane = floatCount / max(channels, 1)
                for ch in 0..<channels {
                    let offset = ch * framesPerPlane
                    for i in 0..<micSamplesToMix {
                        floatPtr[offset + i] = min(max(floatPtr[offset + i] + pendingMicFloats[i], -1.0), 1.0)
                    }
                }
            } else {
                for i in 0..<micSamplesToMix {
                    let mic = pendingMicFloats[i]
                    for ch in 0..<channels {
                        let idx = i * channels + ch
                        floatPtr[idx] = min(max(floatPtr[idx] + mic, -1.0), 1.0)
                    }
                }
            }
            pendingMicFloats.removeFirst(micSamplesToMix)
        }

        // Create new sample buffer with mixed data
        var timingInfo = CMSampleTimingInfo()
        CMSampleBufferGetSampleTimingInfo(systemBuffer, at: 0, timingInfoOut: &timingInfo)
        var sampleSize = CMSampleBufferGetSampleSize(systemBuffer, at: 0)
        let numSamples = CMSampleBufferGetNumSamples(systemBuffer)

        var newSampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: newBlock, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDesc,
            sampleCount: numSamples, sampleTimingEntryCount: 1, sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize,
            sampleBufferOut: &newSampleBuffer
        ) == noErr else {
            return Self.applyGain(to: systemBuffer, gain: systemAudioGainMixed)
        }

        return newSampleBuffer
    }

    // MARK: - Audio Gain

    private static func applyGain(to sampleBuffer: CMSampleBuffer, gain: Float) -> CMSampleBuffer? {
        guard gain != 1.0 else { return sampleBuffer }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else {
            return nil
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return nil
        }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else {
            return nil
        }

        var mutableBlockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: length,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: length,
            flags: 0,
            blockBufferOut: &mutableBlockBuffer
        ) == noErr, let newBlock = mutableBlockBuffer else {
            return nil
        }

        guard CMBlockBufferReplaceDataBytes(with: data, blockBuffer: newBlock, offsetIntoDestination: 0, dataLength: length) == noErr else {
            return nil
        }

        var newDataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(newBlock, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &newDataPointer) == noErr,
              let newData = newDataPointer else {
            return nil
        }

        let formatID = asbd.pointee.mFormatID

        if formatID == kAudioFormatLinearPCM {
            let formatFlags = asbd.pointee.mFormatFlags

            if formatFlags & kAudioFormatFlagIsFloat != 0 {
                let sampleCount = length / MemoryLayout<Float>.size
                let floatPtr = newData.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
                for i in 0..<sampleCount {
                    floatPtr[i] = min(max(floatPtr[i] * gain, -1.0), 1.0)
                }
            } else if asbd.pointee.mBitsPerChannel == 16 {
                let sampleCount = length / MemoryLayout<Int16>.size
                let int16Ptr = newData.withMemoryRebound(to: Int16.self, capacity: sampleCount) { $0 }
                for i in 0..<sampleCount {
                    let amplified = Float(int16Ptr[i]) * gain
                    int16Ptr[i] = Int16(max(min(amplified, Float(Int16.max)), Float(Int16.min)))
                }
            } else {
                return nil
            }
        } else {
            return nil
        }

        var newSampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo()
        let numSamples = CMSampleBufferGetNumSamples(sampleBuffer)
        CMSampleBufferGetSampleTimingInfo(sampleBuffer, at: 0, timingInfoOut: &timingInfo)

        var sampleSize = CMSampleBufferGetSampleSize(sampleBuffer, at: 0)

        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: newBlock,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDesc,
            sampleCount: numSamples,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timingInfo,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &newSampleBuffer
        ) == noErr else {
            return nil
        }

        return newSampleBuffer
    }
}
