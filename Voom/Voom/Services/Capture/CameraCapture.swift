import Foundation
import AVFoundation
import os

/// Thread-safe box for sharing the capture session across actor boundaries.
/// Written once during startCapture(), read-only afterwards.
final class CaptureSessionBox: @unchecked Sendable {
    private(set) var session: AVCaptureSession?
    func set(_ session: AVCaptureSession) { self.session = session }
}

actor CameraCapture {
    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private let delegateHandler = CameraDelegateHandler()

    /// Access the capture session from any isolation context (no await needed).
    nonisolated let sessionBox = CaptureSessionBox()

    nonisolated var latestPixelBuffer: CVPixelBuffer? {
        delegateHandler.latestPixelBuffer
    }

    func startCapture() async throws {
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
    /// Falls back to the highest-fps format available if 60fps isn't supported.
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
                // Exact: meets both resolution and fps targets
                if Int(dims.width) >= targetWidth && Int(dims.height) >= targetHeight
                    && range.maxFrameRate >= targetFPS {
                    if bestExact == nil || pixels < bestExact!.pixels {
                        bestExact = (format, targetFPS, pixels)
                    }
                }
                // Fallback: highest fps regardless of resolution
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

    /// Pre-add the mic input to the session so it won't need reconfiguration later.
    /// Call this right after startCapture() to avoid preview flicker when recording begins.
    func prepareForMic() async throws {
        guard let session = captureSession else { return }
        guard audioOutput == nil else { return } // already prepared

        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noMicAvailable
        }

        let micInput = try AVCaptureDeviceInput(device: mic)
        session.beginConfiguration()
        if session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let output = AVCaptureAudioDataOutput()
        // Don't set delegate yet — will be set when recording starts
        if session.canAddOutput(output) {
            session.addOutput(output)
            self.audioOutput = output
        }
        session.commitConfiguration()
    }

    func startMicCapture(handler: @escaping @Sendable (CMSampleBuffer) -> Void) async throws {
        guard let session = captureSession else {
            // Create a new session if needed (mic-only case)
            let newSession = AVCaptureSession()
            newSession.beginConfiguration()
            try addMicInput(to: newSession, handler: handler)
            newSession.commitConfiguration()
            newSession.startRunning()
            self.captureSession = newSession
            return
        }

        // If mic was pre-added via prepareForMic(), just set the handler
        if let existingAudioOutput = audioOutput {
            delegateHandler.micHandler = handler
            existingAudioOutput.setSampleBufferDelegate(delegateHandler, queue: .global(qos: .userInteractive))
            return
        }

        session.beginConfiguration()
        try addMicInput(to: session, handler: handler)
        session.commitConfiguration()
    }

    private func addMicInput(to session: AVCaptureSession, handler: @escaping @Sendable (CMSampleBuffer) -> Void) throws {
        guard let mic = AVCaptureDevice.default(for: .audio) else {
            throw CaptureError.noMicAvailable
        }

        let micInput = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(micInput) else {
            throw CaptureError.cannotAddInput
        }
        session.addInput(micInput)

        let audioOutput = AVCaptureAudioDataOutput()
        delegateHandler.micHandler = handler
        audioOutput.setSampleBufferDelegate(delegateHandler, queue: .global(qos: .userInteractive))

        guard session.canAddOutput(audioOutput) else {
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(audioOutput)
        self.audioOutput = audioOutput
    }

    func setVideoFrameHandler(_ handler: CameraFrameRecordHandler?) {
        delegateHandler.recordHandler = handler
    }

    func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil
        audioOutput = nil
    }
}

// MARK: - Delegate Handler

final class CameraDelegateHandler: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?
    var micHandler: (@Sendable (CMSampleBuffer) -> Void)?
    var recordHandler: CameraFrameRecordHandler?

    var latestPixelBuffer: CVPixelBuffer? {
        lock.withLock { _latestPixelBuffer }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output is AVCaptureVideoDataOutput {
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                lock.withLock { _latestPixelBuffer = pixelBuffer }
                let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                recordHandler?.handleFrame(pixelBuffer, at: time)
            }
        } else if output is AVCaptureAudioDataOutput {
            micHandler?(sampleBuffer)
        }
    }
}

// MARK: - Errors

enum CaptureError: LocalizedError {
    case noCameraAvailable
    case noMicAvailable
    case cannotAddInput
    case cannotAddOutput

    var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No camera found"
        case .noMicAvailable: "No microphone found"
        case .cannotAddInput: "Cannot add capture input"
        case .cannotAddOutput: "Cannot add capture output"
        }
    }
}
