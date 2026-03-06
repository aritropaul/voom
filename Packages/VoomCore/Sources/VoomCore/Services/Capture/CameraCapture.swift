import Foundation
import AVFoundation
import os

// MARK: - Camera Frame Handler Protocol

/// Protocol for receiving camera video frames. Implemented by VoomApp's CameraFrameRecordHandler.
public protocol CameraFrameHandler: AnyObject {
    func handleFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime)
}

// MARK: - Capture Session Box

/// Thread-safe box for sharing the capture session across actor boundaries.
/// Written once during startCapture(), read-only afterwards.
public final class CaptureSessionBox: @unchecked Sendable {
    public private(set) var session: AVCaptureSession?
    public func set(_ session: AVCaptureSession) { self.session = session }
    public init() {}
}

// MARK: - Camera Capture

public actor CameraCapture {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioEngine: AVAudioEngine?
    private let delegateHandler = CameraDelegateHandler()

    /// Access the capture session from any isolation context (no await needed).
    public nonisolated let sessionBox = CaptureSessionBox()

    public nonisolated var latestPixelBuffer: CVPixelBuffer? {
        delegateHandler.latestPixelBuffer
    }

    public init() {}

    public func startCapture() async throws {
        let session = AVCaptureSession()
        session.beginConfiguration()

        // Camera input
        guard let camera = AVCaptureDevice.default(for: .video) else {
            throw CaptureError.noCameraAvailable
        }

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(cameraInput)

        // Configure for 720p at 60fps — find the best matching format
        try camera.lockForConfiguration()
        if let match = Self.bestFormat(for: camera, targetWidth: 1280, targetHeight: 720, targetFPS: 60) {
            camera.activeFormat = match.format
            let duration = CMTime(value: 1, timescale: Int32(match.fps))
            camera.activeVideoMinFrameDuration = duration
            camera.activeVideoMaxFrameDuration = duration
        }
        camera.unlockForConfiguration()

        // Video output for pixel buffers
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegateHandler, queue: .global(qos: .userInteractive))

        guard session.canAddOutput(videoOutput) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput

        session.commitConfiguration()
        session.startRunning()
        self.captureSession = session
        sessionBox.set(session)
    }

    /// Find the smallest format that supports at least the target resolution and frame rate.
    private static func bestFormat(
        for device: AVCaptureDevice,
        targetWidth: Int,
        targetHeight: Int,
        targetFPS: Double
    ) -> (format: AVCaptureDevice.Format, fps: Double)? {
        var bestExact: (format: AVCaptureDevice.Format, fps: Double, pixels: Int)?
        var bestFallback: (format: AVCaptureDevice.Format, fps: Double)?

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dims.width) * Int(dims.height)

            for range in format.videoSupportedFrameRateRanges {
                if Int(dims.width) >= targetWidth && Int(dims.height) >= targetHeight
                    && range.maxFrameRate >= targetFPS {
                    if bestExact == nil || pixels < bestExact!.pixels {
                        bestExact = (format, targetFPS, pixels)
                    }
                }
                if bestFallback == nil || range.maxFrameRate > bestFallback!.fps {
                    bestFallback = (format, range.maxFrameRate)
                }
            }
        }

        if let exact = bestExact {
            return (exact.format, exact.fps)
        }
        return bestFallback
    }

    /// No-op — mic now uses AVAudioEngine (separate from camera AVCaptureSession).
    public func prepareForMic() async throws {}

    public func startMicCapture(handler: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            throw CaptureError.noMicAvailable
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { [weak self] buffer, time in
            guard self != nil else { return }
            if let sampleBuffer = Self.convertToSampleBuffer(buffer: buffer, time: time) {
                handler(sampleBuffer)
            }
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - AVAudioPCMBuffer → CMSampleBuffer Conversion

    private static func convertToSampleBuffer(buffer: AVAudioPCMBuffer, time: AVAudioTime) -> CMSampleBuffer? {
        let frameCount = buffer.frameLength
        guard frameCount > 0 else { return nil }

        let format = buffer.format
        let channels = Int(format.channelCount)
        let sampleRate = format.sampleRate

        guard let floatData = buffer.floatChannelData else { return nil }

        // Build interleaved PCM data
        let totalSamples = Int(frameCount) * channels
        var interleaved = [Float](repeating: 0, count: totalSamples)

        if channels == 1 {
            let src = floatData[0]
            for i in 0..<Int(frameCount) {
                interleaved[i] = src[i]
            }
        } else {
            for frame in 0..<Int(frameCount) {
                for ch in 0..<channels {
                    interleaved[frame * channels + ch] = floatData[ch][frame]
                }
            }
        }

        let dataSize = totalSamples * MemoryLayout<Float>.size

        var blockBuffer: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataSize,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataSize,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr, let block = blockBuffer else { return nil }

        guard interleaved.withUnsafeBytes({ bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: dataSize
            )
        }) == noErr else { return nil }

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channels * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channels * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )

        var formatDescription: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        ) == noErr, let fmtDesc = formatDescription else { return nil }

        let seconds = AVAudioTime.seconds(forHostTime: time.hostTime)
        let pts = CMTime(seconds: seconds, preferredTimescale: CMTimeScale(sampleRate))

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = dataSize
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: block,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: fmtDesc,
            sampleCount: CMItemCount(frameCount),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        ) == noErr else { return nil }

        return sampleBuffer
    }

    public func setVideoFrameHandler(_ handler: (any CameraFrameHandler)?) {
        delegateHandler.recordHandler = handler
    }

    public func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil

        if let engine = audioEngine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            audioEngine = nil
        }
    }
}

// MARK: - Delegate Handler

public final class CameraDelegateHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?
    public var recordHandler: (any CameraFrameHandler)?

    public var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { _latestPixelBuffer }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
            lock.withLock { _latestPixelBuffer = pixelBuffer }
            let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            recordHandler?.handleFrame(pixelBuffer, at: time)
        }
    }
}

// MARK: - Errors

public enum CaptureError: LocalizedError {
    case noCameraAvailable
    case noMicAvailable
    case cannotAddInput
    case cannotAddOutput

    public var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No camera found"
        case .noMicAvailable: "No microphone found"
        case .cannotAddInput: "Cannot add capture input"
        case .cannotAddOutput: "Cannot add capture output"
        }
    }
}
