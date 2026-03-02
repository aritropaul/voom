import Foundation
import AVFoundation
import CoreVideo

final class VideoWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "voom.videowriter", qos: .userInteractive)
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var systemAudioInput: AVAssetWriterInput?
    private var micAudioInput: AVAssetWriterInput?
    private var isSessionStarted = false
    private var lastVideoTime: CMTime = .zero

    // Audio gain multipliers
    private let systemAudioGain: Float = 1.5
    private let micAudioGain: Float = 4.0

    func configure(
        outputURL: URL,
        width: Int,
        height: Int,
        hasSystemAudio: Bool,
        hasMicAudio: Bool
    ) throws {
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        // Video input - HEVC (H.265) with hardware acceleration on Apple Silicon
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 10_000_000, // 10 Mbps — excellent quality for HEVC screen recording
                AVVideoExpectedSourceFrameRateKey: 60,
                AVVideoMaxKeyFrameIntervalKey: 120, // 2s GOP — HEVC handles longer GOPs efficiently
                AVVideoAllowFrameReorderingKey: false // Lower latency for real-time recording
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

        // System audio input
        if hasSystemAudio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 192000
            ]
            let sysAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            sysAudioInput.expectsMediaDataInRealTime = true
            writer.add(sysAudioInput)
            self.systemAudioInput = sysAudioInput
        }

        // Mic audio input
        if hasMicAudio {
            let micSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 128000
            ]
            let micInput = AVAssetWriterInput(mediaType: .audio, outputSettings: micSettings)
            micInput.expectsMediaDataInRealTime = true
            writer.add(micInput)
            self.micAudioInput = micInput
        }

        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        self.assetWriter = writer
        self.isSessionStarted = true
    }

    func appendPixelBuffer(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
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

    func appendSystemAudioSample(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [self] in
            guard let input = systemAudioInput,
                  input.isReadyForMoreMediaData,
                  isSessionStarted else { return }
            let boosted = Self.applyGain(to: buffer, gain: systemAudioGain)
            input.append(boosted ?? buffer)
        }
    }

    func appendMicAudioSample(_ sampleBuffer: CMSampleBuffer) {
        nonisolated(unsafe) let buffer = sampleBuffer
        queue.async { [self] in
            guard let input = micAudioInput,
                  input.isReadyForMoreMediaData,
                  isSessionStarted else { return }
            let boosted = Self.applyGain(to: buffer, gain: micAudioGain)
            input.append(boosted ?? buffer)
        }
    }

    func finalize() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [self] in
                guard let writer = assetWriter else {
                    continuation.resume()
                    return
                }

                videoInput?.markAsFinished()
                systemAudioInput?.markAsFinished()
                micAudioInput?.markAsFinished()

                writer.finishWriting {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.pixelBufferAdaptor = nil
                    self.systemAudioInput = nil
                    self.micAudioInput = nil
                    self.isSessionStarted = false
                    self.lastVideoTime = .zero
                    continuation.resume()
                }
            }
        }
    }

    // MARK: - Audio Gain

    /// Apply gain multiplier to audio sample buffer.
    /// Works with Int16 and Float32 PCM formats.
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

        // Create a mutable copy of the block buffer data
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
                // Float32 PCM
                let sampleCount = length / MemoryLayout<Float>.size
                let floatPtr = newData.withMemoryRebound(to: Float.self, capacity: sampleCount) { $0 }
                for i in 0..<sampleCount {
                    floatPtr[i] = min(max(floatPtr[i] * gain, -1.0), 1.0)
                }
            } else if asbd.pointee.mBitsPerChannel == 16 {
                // Int16 PCM
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
            // Non-PCM format (e.g., compressed) — can't apply gain directly
            return nil
        }

        // Create new sample buffer with the modified data
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
