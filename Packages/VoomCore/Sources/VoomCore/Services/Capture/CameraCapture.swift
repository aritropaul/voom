import Foundation
import AVFoundation
import CoreMedia
import os
import VoomExceptionCatch

private let cameraLogger = Logger(subsystem: "com.voom.app", category: "CameraCapture")

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
    private var micSession: AVCaptureSession?
    private var micDelegate: MicAudioDelegate?
    private let delegateHandler = CameraDelegateHandler()

    /// Access the capture session from any isolation context (no await needed).
    public nonisolated let sessionBox = CaptureSessionBox()

    public nonisolated var latestPixelBuffer: CVPixelBuffer? {
        delegateHandler.latestPixelBuffer
    }

    public init() {}

    /// Opens the preferred camera, then any remaining connected camera if that one fails.
    /// Continuity Camera is last because it is often macOS's default while unavailable.
    @discardableResult
    public func startCapture(deviceID: String? = nil) async throws -> String {
        guard await Self.ensureCameraAuthorized() else {
            throw CaptureError.cameraAccessDenied
        }

        let candidates = CameraDeviceCatalog.devicesInPreferenceOrder(
            preferredID: deviceID,
            devices: CameraDeviceCatalog.availableDevices()
        )
        guard !candidates.isEmpty else {
            throw CaptureError.noCameraAvailable
        }

        var lastError: Error = CaptureError.noCameraAvailable
        for candidate in candidates {
            do {
                return try self.openSession(deviceID: candidate.uniqueID)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private func openSession(deviceID: String) throws -> String {
        guard let camera = AVCaptureDevice(uniqueID: deviceID) else {
            throw CaptureError.noCameraAvailable
        }

        let session = AVCaptureSession()
        session.beginConfiguration()

        let cameraInput = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(cameraInput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }
        session.addInput(cameraInput)
        Self.applyPreferredFormat(to: camera)

        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(delegateHandler, queue: .global(qos: .userInitiated))

        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(videoOutput)
        self.videoOutput = videoOutput

        session.commitConfiguration()
        session.startRunning()
        self.captureSession = session
        sessionBox.set(session)
        return camera.uniqueID
    }

    private static func ensureCameraAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .video)
        default:
            return false
        }
    }

    /// USB/DAL cameras (Lenovo and similar) throw NSException from
    /// `activeVideoMinFrameDuration`. Swift `catch` does not stop that, so
    /// format setup is optional: preview still starts on the device default.
    private static func applyPreferredFormat(to camera: AVCaptureDevice) {
        guard let match = bestFormat(for: camera, targetWidth: 1280, targetHeight: 720, targetFPS: 30) else {
            return
        }

        do {
            try camera.lockForConfiguration()
        } catch {
            cameraLogger.error("Camera lockForConfiguration failed: \(error.localizedDescription)")
            return
        }
        defer { camera.unlockForConfiguration() }

        var formatError: NSError?
        if !VoomCatchException({
            camera.activeFormat = match.format
        }, &formatError) {
            cameraLogger.error("activeFormat rejected: \(formatError?.localizedDescription ?? "unknown")")
            return
        }

        // Do not set min/max frame duration. USB/DAL cameras (Lenovo) abort the
        // process from that setter even when the advertised range includes 30fps.

    }

    /// Smallest format at least `targetWidth`×`targetHeight` whose range can
    /// serve `targetFPS`, otherwise the highest-rate format. Duration is always
    /// taken from the range so UVC metadata is not converted through Int32 fps.
    private static func bestFormat(
        for device: AVCaptureDevice,
        targetWidth: Int,
        targetHeight: Int,
        targetFPS: Double
    ) -> (format: AVCaptureDevice.Format, frameDuration: CMTime)? {
        var bestExact: (format: AVCaptureDevice.Format, frameDuration: CMTime, pixels: Int)?
        var bestFallback: (format: AVCaptureDevice.Format, frameDuration: CMTime, fps: Double)?

        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Int(dims.width) * Int(dims.height)

            for range in format.videoSupportedFrameRateRanges {
                let duration = CameraFrameTiming.clampedDuration(
                    desiredFPS: targetFPS,
                    minDuration: range.minFrameDuration,
                    maxDuration: range.maxFrameDuration
                )
                if Int(dims.width) >= targetWidth && Int(dims.height) >= targetHeight
                    && range.maxFrameRate >= targetFPS {
                    if bestExact == nil || pixels < bestExact!.pixels {
                        bestExact = (format, duration, pixels)
                    }
                }
                if bestFallback == nil || range.maxFrameRate > bestFallback!.fps {
                    bestFallback = (format, duration, range.maxFrameRate)
                }
            }
        }

        if let exact = bestExact {
            return (exact.format, exact.frameDuration)
        }
        if let fallback = bestFallback {
            return (fallback.format, fallback.frameDuration)
        }
        return nil
    }

    /// Microphone capture uses its own session, independent of camera and playback.
    public func prepareForMic() async throws {}

    public func startMicCapture(
        deviceID: String? = nil,
        handler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) async throws {
        guard await Self.ensureMicAuthorized() else {
            throw CaptureError.noMicAvailable
        }

        guard let resolved = MicDeviceCatalog.recordingDevice(
            preferredID: deviceID,
            devices: MicDeviceCatalog.availableDevices()
        ) else {
            if deviceID != nil {
                throw CaptureError.selectedMicUnavailable("The selected microphone")
            }
            throw CaptureError.noMicAvailable
        }
        cameraLogger.notice(
            "Recording microphone \(resolved.localizedName, privacy: .public) bluetooth=\(resolved.isBluetooth)"
        )

        do {
            try startAVCaptureMic(
                preferredID: resolved.uniqueID,
                preferredName: resolved.localizedName,
                headset: resolved.isBluetooth,
                dormantHeadset: resolved.isBluetooth && !resolved.hasInput,
                handler: handler
            )
        } catch {
            if deviceID != nil {
                cameraLogger.error("Selected microphone failed: \(error.localizedDescription, privacy: .public)")
                throw CaptureError.selectedMicUnavailable(resolved.localizedName)
            }
            throw error
        }
    }

    public func stopMicCapture() {
        micSession?.stopRunning()
        micSession = nil
        micDelegate = nil
    }

    private func startAVCaptureMic(
        preferredID: String?,
        preferredName: String?,
        headset: Bool,
        dormantHeadset: Bool,
        handler: @escaping @Sendable (CMSampleBuffer) -> Void
    ) throws {
        let captureDevice = MicAudioDevices.captureDevice(
            preferredID: preferredID,
            preferredName: preferredName,
            allowBluetoothNameMatch: dormantHeadset
        )
        guard let captureDevice else {
            throw CaptureError.noMicAvailable
        }
        cameraLogger.notice("AVCapture microphone \(captureDevice.localizedName, privacy: .public)")

        let session = AVCaptureSession()
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddInput
        }
        session.addInput(input)

        let output = AVCaptureAudioDataOutput()
        if !headset {
            output.audioSettings = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 48_000,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false
            ]
        }
        let beautifier = AppDefaults.voiceEnhanceEnabled
            ? VoiceBeautifier(sampleRate: MicPCM.targetSampleRate, headset: headset)
            : nil
        let delegate = MicAudioDelegate(beautifier: beautifier, handler: handler)
        output.setSampleBufferDelegate(delegate, queue: DispatchQueue(label: "voom.mic", qos: .userInitiated))
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureError.cannotAddOutput
        }
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
        guard session.isRunning else {
            throw CaptureError.noMicAvailable
        }

        micSession = session
        micDelegate = delegate
    }

    private static func ensureMicAuthorized() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public func setVideoFrameHandler(_ handler: (any CameraFrameHandler)?) {
        delegateHandler.recordHandler = handler
    }

    public func stopCapture() {
        captureSession?.stopRunning()
        captureSession = nil
        videoOutput = nil

        stopMicCapture()
    }
}

// MARK: - Frame duration

enum CameraFrameTiming {
    static func clampedDuration(desiredFPS: Double, minDuration: CMTime, maxDuration: CMTime) -> CMTime {
        let fps = max(desiredFPS, 1)
        let desired = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)
        if CMTimeCompare(desired, minDuration) < 0 { return minDuration }
        if CMTimeCompare(desired, maxDuration) > 0 { return maxDuration }
        return desired
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
    case selectedMicUnavailable(String)
    case cannotAddInput
    case cannotAddOutput
    case cameraAccessDenied
    case screenAccessDenied

    public var errorDescription: String? {
        switch self {
        case .noCameraAvailable: "No camera found"
        case .noMicAvailable: "No microphone found"
        case .selectedMicUnavailable(let name): "\(name) could not be opened. Connect it and choose it again, or select another microphone."
        case .cannotAddInput: "Cannot add capture input"
        case .cannotAddOutput: "Cannot add capture output"
        case .cameraAccessDenied: "Camera access denied"
        case .screenAccessDenied: ScreenCaptureAccess.deniedMessage
        }
    }
}
