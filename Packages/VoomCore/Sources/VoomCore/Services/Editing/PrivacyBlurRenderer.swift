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
            // Resume exactly once: the ready-callback can fire again after a
            // failure path has already finished the input.
            var finished = false
            let finish: () -> Void = {
                guard !finished else { return }
                finished = true
                videoInput.markAsFinished()
                continuation.resume()
            }
            videoInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.voom.blur.video")) {
                while videoInput.isReadyForMoreMediaData {
                    guard !finished else { return }

                    // Per-frame autoreleasepool: CIImage/CVPixelBuffer temporaries
                    // otherwise accumulate for the whole export (tens of thousands
                    // of frames) before anything is released. The counter mutation
                    // stays outside the pool closure (Swift 6 sendable-capture rule).
                    let step: (stop: Bool, advanced: Bool) = autoreleasepool {
                        // A failed writer never becomes ready again — without this
                        // check the continuation would leak and finalize would hang.
                        if writer.status == .failed || reader.status == .failed {
                            return (stop: true, advanced: false)
                        }

                        guard let sampleBuffer = videoOutput.copyNextSampleBuffer() else {
                            return (stop: true, advanced: false)
                        }

                        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                        let timeSeconds = CMTimeGetSeconds(presentationTime)

                        // Non-video sample buffers have no image buffer — skip them
                        // instead of crashing on a force unwrap.
                        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                            return (stop: false, advanced: false)
                        }

                        // Check which regions are active
                        let activeRegions = regions.filter { $0.isActive(at: timeSeconds) }

                        if activeRegions.isEmpty {
                            // No blur needed, pass through
                            adaptor.append(pixelBuffer, withPresentationTime: presentationTime)
                        } else {

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

                        return (stop: false, advanced: true)
                    }

                    if step.advanced {
                        framesProcessed += 1
                        if framesProcessed % 30 == 0 {
                            progress?(Double(framesProcessed) / Double(totalFrames))
                        }
                    }
                    if step.stop {
                        finish()
                        return
                    }
                }
            }
        }

        // Copy audio
        for (audioOutput, audioInput) in audioInputs {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                var finished = false
                let finish: () -> Void = {
                    guard !finished else { return }
                    finished = true
                    audioInput.markAsFinished()
                    continuation.resume()
                }
                audioInput.requestMediaDataWhenReady(on: DispatchQueue(label: "com.voom.blur.audio")) {
                    while audioInput.isReadyForMoreMediaData {
                        guard !finished else { return }
                        let shouldStop: Bool = autoreleasepool {
                            if writer.status == .failed || reader.status == .failed {
                                return true
                            }
                            guard let buffer = audioOutput.copyNextSampleBuffer() else {
                                return true
                            }
                            audioInput.append(buffer)
                            return false
                        }
                        if shouldStop {
                            finish()
                            return
                        }
                    }
                }
            }
        }

        await writer.finishWriting()

        if writer.status == .failed {
            throw writer.error ?? BlurError.writeFailed
        }
        if reader.status == .failed {
            throw reader.error ?? BlurError.writeFailed
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
