import AVFoundation
import CoreImage
import os

private let blurLogger = Logger(subsystem: "com.voom.app", category: "PrivacyBlur")

public actor PrivacyBlurRenderer {
    public static let shared = PrivacyBlurRenderer()
    private init() {}

    public func applyBlur(
        sourceURL: URL,
        regions: [BlurRegion],
        outputURL: URL,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw BlurError.noVideoTrack
        }

        let size = try await videoTrack.load(.naturalSize)
        let transform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let transformedSize = size.applying(transform)
        let videoSize = CGSize(width: abs(transformedSize.width), height: abs(transformedSize.height))

        // Set up reader
        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        reader.add(videoOutput)

        // Set up writer
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(videoSize.width),
            AVVideoHeightKey: Int(videoSize.height)
        ])
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(videoSize.width),
                kCVPixelBufferHeightKey as String: Int(videoSize.height)
            ]
        )
        writer.add(videoInput)

        // Copy audio tracks
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        var audioInputs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for audioTrack in audioTracks {
            let audioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
            reader.add(audioOutput)
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
            writer.add(audioInput)
            audioInputs.append((audioOutput, audioInput))
        }

        reader.startReading()
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        let ciContext = CIContext(options: [.useSoftwareRenderer: false])
        let totalSeconds = CMTimeGetSeconds(duration)
        var framesProcessed = 0
        let totalFrames = max(1, Int(totalSeconds * Double(nominalFrameRate)))

        // Process video frames
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.voom.blur.video")) {
                while videoInput.isReadyForMoreMediaData {
                    guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                        videoInput.markAsFinished()
                        continuation.resume()
                        return
                    }

                    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                    let timeSeconds = CMTimeGetSeconds(presentationTime)

                    // Check which regions are active
                    let activeRegions = regions.filter { $0.isActive(at: timeSeconds) }

                    if activeRegions.isEmpty {
                        // No blur needed, pass through
                        adaptor.append(CMSampleBufferGetImageBuffer(sampleBuffer)!, withPresentationTime: presentationTime)
                    } else {
                        // Apply blur
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            adaptor.append(CMSampleBufferGetImageBuffer(sampleBuffer)!, withPresentationTime: presentationTime)
                            continue
                        }

                        var image = CIImage(cvPixelBuffer: pixelBuffer)

                        for region in activeRegions {
                            let pixelRect = region.rect.toCGRect(in: videoSize)

                            // Create blurred version of the region
                            guard let blurFilter = CIFilter(name: "CIGaussianBlur") else { continue }
                            let cropped = image.cropped(to: pixelRect)
                            blurFilter.setValue(cropped, forKey: kCIInputImageKey)
                            blurFilter.setValue(30.0, forKey: kCIInputRadiusKey)

                            guard let blurred = blurFilter.outputImage?.cropped(to: pixelRect) else { continue }
                            image = blurred.composited(over: image)
                        }

                        // Render to pixel buffer
                        if let pool = adaptor.pixelBufferPool {
                            var outputBuffer: CVPixelBuffer?
                            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outputBuffer)
                            if let outputBuffer {
                                ciContext.render(image, to: outputBuffer)
                                adaptor.append(outputBuffer, withPresentationTime: presentationTime)
                            }
                        }
                    }

                    framesProcessed += 1
                    if framesProcessed % 30 == 0 {
                        progress?(Double(framesProcessed) / Double(totalFrames))
                    }
                }
            }
        }

        // Copy audio
        for (audioOutput, audioInput) in audioInputs {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.voom.blur.audio")) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let buffer = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            continuation.resume()
                            return
                        }
                        audioInput.append(buffer)
                    }
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? BlurError.writeFailed
        }

        progress?(1.0)
        blurLogger.info("[Voom] Privacy blur applied: \(regions.count) regions, \(framesProcessed) frames")
    }

    public enum BlurError: Error, LocalizedError {
        case noVideoTrack
        case writeFailed

        public var errorDescription: String? {
            switch self {
            case .noVideoTrack: return "No video track found"
            case .writeFailed: return "Failed to write blurred video"
            }
        }
    }
}
