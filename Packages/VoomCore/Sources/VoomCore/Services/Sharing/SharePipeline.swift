import Foundation
import AVFoundation

// MARK: - Pipeline Result

public struct PipelineResult: Sendable {
    public let optimizedURL: URL
    public let fileSize: Int64
}

// MARK: - Share Pipeline

public actor SharePipeline {
    public static let shared = SharePipeline()

    private init() {}

    public func optimize(sourceURL: URL, progress: @Sendable (Double) -> Void) async throws -> PipelineResult {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)
        let totalSeconds = CMTimeGetSeconds(duration)
        guard totalSeconds > 0 else { throw SharePipelineError.invalidSource }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard let videoTrack = videoTracks.first else { throw SharePipelineError.noVideoTrack }

        let naturalSize = try await videoTrack.load(.naturalSize)

        // Output temp file
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voom-share-\(UUID().uuidString).mp4")

        // Reader
        let reader = try AVAssetReader(asset: asset)

        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        videoOutput.alwaysCopiesSampleData = false
        reader.add(videoOutput)

        // Audio: mix all tracks into one output
        var audioOutput: AVAssetReaderAudioMixOutput?
        if !audioTracks.isEmpty {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
            let mixOutput = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: audioSettings)
            mixOutput.alwaysCopiesSampleData = false
            reader.add(mixOutput)
            audioOutput = mixOutput
        }

        // Writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)

        let videoInputSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(naturalSize.width),
            AVVideoHeightKey: Int(naturalSize.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 2_000_000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoMaxKeyFrameIntervalKey: 60,
            ],
        ]
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoInputSettings)
        videoInput.expectsMediaDataInRealTime = false
        // Preserve source transform
        let transform = try await videoTrack.load(.preferredTransform)
        videoInput.transform = transform
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if audioOutput != nil {
            let audioInputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000,
            ]
            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioInputSettings)
            aInput.expectsMediaDataInRealTime = false
            writer.add(aInput)
            audioInput = aInput
        }

        // Start
        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Process video
        while videoInput.isReadyForMoreMediaData {
            if let sampleBuffer = videoOutput.copyNextSampleBuffer() {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                let pct = CMTimeGetSeconds(pts) / totalSeconds
                progress(min(pct, 1.0))
                videoInput.append(sampleBuffer)
            } else {
                break
            }
        }
        videoInput.markAsFinished()

        // Process audio
        if let audioOutput, let audioInput {
            while audioInput.isReadyForMoreMediaData {
                if let sampleBuffer = audioOutput.copyNextSampleBuffer() {
                    audioInput.append(sampleBuffer)
                } else {
                    break
                }
            }
            audioInput.markAsFinished()
        }

        // Finalize
        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? SharePipelineError.writeFailed
        }
        if reader.status == .failed {
            throw reader.error ?? SharePipelineError.readFailed
        }

        let attrs = try FileManager.default.attributesOfItem(atPath: outputURL.path(percentEncoded: false))
        let fileSize = attrs[.size] as? Int64 ?? 0

        return PipelineResult(optimizedURL: outputURL, fileSize: fileSize)
    }
}

// MARK: - Errors

public enum SharePipelineError: LocalizedError {
    case invalidSource
    case noVideoTrack
    case readFailed
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSource: return "Invalid source video"
        case .noVideoTrack: return "No video track found"
        case .readFailed: return "Failed to read source video"
        case .writeFailed: return "Failed to write optimized video"
        }
    }
}
