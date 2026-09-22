import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import CoreImage
import VoomCore

public actor ScreenRecorder {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var videoWriter: VideoWriter?
    private var cameraCapture: CameraCapture?
    private let stateProvider: any RecordingStateProvider
    private var isPaused = false
    private var hadWebcam = false
    private var hadSystemAudio = false
    private var hadMicAudio = false
    private var ownsCamera = false
    private var micTimeAdjuster: MicTimeAdjuster?
    private var streamDelegate: StreamStopNotifier?

    public init(stateProvider: any RecordingStateProvider) {
        self.stateProvider = stateProvider
    }

    public func startRecording(
        display: SCDisplay,
        cameraEnabled: Bool,
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        pipPosition: PiPPosition,
        existingCamera: CameraCapture? = nil,
        cropRect: CGRect? = nil,
        window: SCWindow? = nil,
        pipWindowNumber: Int? = nil,
        annotationWindowNumber: Int? = nil
    ) async throws {
        self.hadWebcam = cameraEnabled
        self.hadSystemAudio = systemAudioEnabled
        self.hadMicAudio = micEnabled

        // Start cursor tracking
        await InputTracker.shared.startTracking()

        let storage = RecordingStorage.shared
        let outputURL = await storage.newRecordingURL()

        // Configure screen capture — exclude Voom's own windows EXCEPT the camera PiP
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let voomApp = shareableContent.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter: SCContentFilter

        // Find the camera PiP and annotation windows to include them in the capture
        var exceptWindows: [SCWindow] = []
        if cameraEnabled, let pipWinNum = pipWindowNumber,
           let pipSCWindow = shareableContent.windows.first(where: { $0.windowID == CGWindowID(pipWinNum) }) {
            exceptWindows.append(pipSCWindow)
        }
        if let annotationWinNum = annotationWindowNumber,
           let annotationSCWindow = shareableContent.windows.first(where: { $0.windowID == CGWindowID(annotationWinNum) }) {
            exceptWindows.append(annotationSCWindow)
        }

        if let window {
            // Single-window capture. `desktopIndependentWindow` follows the window
            // as it moves, resizes, or crosses displays, and captures its real
            // content even when another window sits on top — the crop-a-display
            // approach records whatever is visually in that rectangle instead.
            filter = SCContentFilter(desktopIndependentWindow: window)
        } else if let voomApp {
            filter = SCContentFilter(display: display, excludingApplications: [voomApp], exceptingWindows: exceptWindows)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()

        // Capture at native Retina resolution using scaleFactor
        let scaleFactor: Int = await MainActor.run {
            let screen = NSScreen.screens.first {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
            } ?? NSScreen.main
            return Int(screen?.backingScaleFactor ?? 2)
        }

        // Window capture: size from the filter itself. `contentRect` is the
        // window's rect in points and `pointPixelScale` resolves the backing
        // scale even for a window straddling displays of different densities.
        if window != nil {
            config.ignoreShadowsSingleWindow = true
            let pixelWidth = Int((Float(filter.contentRect.width) * filter.pointPixelScale).rounded())
            let pixelHeight = Int((Float(filter.contentRect.height) * filter.pointPixelScale).rounded())
            config.width = max(2, pixelWidth & ~1)
            config.height = max(2, pixelHeight & ~1)
        } else if let cropRect {
            config.sourceRect = cropRect
            let cropWidth = (Int(cropRect.width) * scaleFactor) & ~1
            let cropHeight = (Int(cropRect.height) * scaleFactor) & ~1
            config.width = cropWidth
            config.height = cropHeight
        } else {
            config.width = (display.width * scaleFactor) & ~1
            config.height = (display.height * scaleFactor) & ~1
        }

        let finalWidth = config.width
        let finalHeight = config.height

        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = systemAudioEnabled
        config.sampleRate = 48000
        config.channelCount = 2
        // Keep Voom's own playback out of the capture — otherwise reviewing a
        // recording while starting another one records it back into the new file.
        config.excludesCurrentProcessAudio = true

        // Set up camera reference (for mic capture)
        if cameraEnabled {
            if let existingCamera {
                self.cameraCapture = existingCamera
                self.ownsCamera = false
            } else {
                let camera = CameraCapture()
                try await camera.startCapture()
                self.cameraCapture = camera
                self.ownsCamera = true
            }
        }

        // Set up video writer
        let writer = VideoWriter()
        try writer.configure(
            outputURL: outputURL,
            width: finalWidth,
            height: finalHeight,
            hasSystemAudio: systemAudioEnabled,
            hasMicAudio: micEnabled
        )
        self.videoWriter = writer

        // Create stream output handler.
        //
        // Window capture streams only the target window, so the PiP panel can't
        // be excepted into the filter the way it is for a display capture — the
        // bubble is drawn into each frame here instead.
        var compositor: CameraCompositor?
        if window != nil, cameraEnabled, cameraCapture != nil {
            compositor = CameraCompositor(
                width: finalWidth,
                height: finalHeight,
                pipPosition: pipPosition,
                scale: CGFloat(filter.pointPixelScale)
            )
        }
        let output = StreamOutput(
            videoWriter: writer,
            camera: compositor != nil ? cameraCapture : nil,
            compositor: compositor
        )

        // Set up mic capture if enabled
        if micEnabled {
            let writerRef = writer
            let micTimer = MicTimeAdjuster()
            self.micTimeAdjuster = micTimer
            let outputRef = output
            if let camera = cameraCapture {
                try await camera.startMicCapture { sampleBuffer in
                    guard !outputRef.isPaused else { return }
                    if let retimed = micTimer.retime(sampleBuffer) {
                        writerRef.appendMicAudioSample(retimed)
                    }
                }
            } else {
                let camera = CameraCapture()
                self.cameraCapture = camera
                try await camera.startMicCapture { sampleBuffer in
                    guard !outputRef.isPaused else { return }
                    if let retimed = micTimer.retime(sampleBuffer) {
                        writerRef.appendMicAudioSample(retimed)
                    }
                }
            }
        }
        self.streamOutput = output

        // Start capture
        //
        // A delegate is mandatory, not optional polish: when the captured window
        // closes (or a display is unplugged, or permission is revoked)
        // ScreenCaptureKit stops the stream and this is the ONLY notification.
        // Without it the timer keeps counting against a dead stream and the user
        // gets a truncated file with no explanation.
        let streamDelegate = StreamStopNotifier()
        self.streamDelegate = streamDelegate
        let stream = SCStream(filter: filter, configuration: config, delegate: streamDelegate)
        // .userInitiated, not .userInteractive: the capture+encode feed must
        // stay high-priority but must NOT sit co-equal with the WindowServer
        // and the foreground app. At .userInteractive the 5K60 pipeline starves
        // the user's own interactions — "the whole laptop is laggy once I record."
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInitiated))
        if systemAudioEnabled {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInitiated))
        }

        try await stream.startCapture()
        self.stream = stream

        await MainActor.run {
            self.stateProvider.currentRecordingURL = outputURL
        }
    }

    public func stopRecording() async throws -> UUID? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        // The mic is always ours to release, even when the camera was borrowed
        // from the live preview — otherwise the tap outlives the recording.
        if let camera = cameraCapture {
            await camera.stopMicCapture()
            if ownsCamera { await camera.stopCapture() }
        }
        cameraCapture = nil
        ownsCamera = false

        var finalizeError: Error?
        if let writer = videoWriter, let output = streamOutput {
            output.duplicateLastFrameIfNeeded()
            do {
                try await writer.finalize()
            } catch {
                finalizeError = error
            }
        }
        videoWriter = nil
        streamOutput = nil
        micTimeAdjuster = nil
        streamDelegate = nil

        let outputURL = await MainActor.run { stateProvider.currentRecordingURL }
        if let outputURL {
            // If finalize failed, salvage what we can: a file that still reports
            // a playable duration is worth keeping; a dead file is not a recording.
            if finalizeError != nil {
                let duration = await RecordingStorage.shared.videoDuration(at: outputURL)
                guard duration > 0 else { throw finalizeError! }
            }
            return await saveRecording(
                at: outputURL,
                hasWebcam: hadWebcam,
                hasSystemAudio: hadSystemAudio,
                hasMicAudio: hadMicAudio
            )
        }
        if let finalizeError { throw finalizeError }
        return nil
    }

    public func pause() {
        isPaused = true
        streamOutput?.isPaused = true
        micTimeAdjuster?.notifyPause()
    }

    public func resume() {
        isPaused = false
        micTimeAdjuster?.notifyResume()
        streamOutput?.isPaused = false
    }

    private func saveRecording(at url: URL, hasWebcam: Bool, hasSystemAudio: Bool, hasMicAudio: Bool) async -> UUID {
        let storage = RecordingStorage.shared
        let duration = await storage.videoDuration(at: url)
        let resolution = await storage.videoResolution(at: url)
        let fileSize = await storage.fileSize(at: url)

        // Stop cursor tracking and save events
        let cursorEvents = await InputTracker.shared.stopTracking()

        var recording = Recording(
            title: url.deletingPathExtension().lastPathComponent,
            fileURL: url,
            duration: duration,
            fileSize: fileSize,
            width: resolution.width,
            height: resolution.height,
            hasWebcam: hasWebcam,
            hasSystemAudio: hasSystemAudio,
            hasMicAudio: hasMicAudio
        )

        // Write cursor events sidecar
        if !cursorEvents.isEmpty {
            let sidecarURL = url.deletingPathExtension().appendingPathExtension("cursor.json")
            do {
                try await InputTracker.shared.writeEvents(cursorEvents, sidecarURL: sidecarURL)
                recording.cursorEventsURL = sidecarURL
            } catch {
                // Non-fatal — continue without cursor data
            }
        }

        let thumbURL = await storage.generateThumbnail(for: url, recordingID: recording.id)
        recording.thumbnailURL = thumbURL

        let recordingID = recording.id
        await MainActor.run {
            RecordingStore.shared.add(recording)
        }

        // Auto-transcribe in background if audio is available and setting is enabled
        let autoTranscribeEnabled = AppDefaults.autoTranscribeEnabled
        if autoTranscribeEnabled && (hasSystemAudio || hasMicAudio) {
            await MainActor.run {
                RecordingStore.shared.autoTranscribe(recordingID: recordingID, fileURL: url)
            }
        }

        return recordingID
    }
}

// MicTimeAdjuster lives in VoomCore (shared with MeetingRecorder).

// MARK: - Stream Stop Notifier

/// Turns an unsolicited ScreenCaptureKit stop into an app-level notification so
/// the session controller can finalize the file and tell the user why.
final class StreamStopNotifier: NSObject, SCStreamDelegate, @unchecked Sendable {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NotificationCenter.default.post(
            name: .captureStreamStopped,
            object: nil,
            userInfo: [captureStreamErrorKey: error]
        )
    }
}

// MARK: - StreamOutput

public final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let videoWriter: VideoWriter
    /// Only set for single-window capture, where the camera bubble has to be
    /// drawn into the frame rather than captured as its own window.
    private let camera: CameraCapture?
    private let compositor: CameraCompositor?
    private let lock = NSLock()

    // Separate clock tracking for screen and audio
    private var firstScreenTime: CMTime?
    private var firstAudioTime: CMTime?
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastWriteTime: CMTime = .zero

    // Pause tracking
    private var _isPaused = false
    private var pauseStartScreenTime: CMTime?
    private var pauseStartAudioTime: CMTime?
    private var accumulatedScreenPause: CMTime = .zero
    private var accumulatedAudioPause: CMTime = .zero

    nonisolated(unsafe) private static var lastRMSCheckTime: Date = .distantPast

    public var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set {
            lock.lock()
            if newValue && !_isPaused {
                _isPaused = true
                pauseStartScreenTime = nil
                pauseStartAudioTime = nil
            } else if !newValue && _isPaused {
                _isPaused = false
            }
            lock.unlock()
        }
    }

    public init(videoWriter: VideoWriter, camera: CameraCapture? = nil, compositor: CameraCompositor? = nil) {
        self.videoWriter = videoWriter
        self.camera = camera
        self.compositor = compositor
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        let paused = _isPaused

        switch type {
        case .screen:
            if paused {
                if pauseStartScreenTime == nil {
                    pauseStartScreenTime = timestamp
                }
                lock.unlock()
                return
            }
            if let pauseStart = pauseStartScreenTime {
                accumulatedScreenPause = CMTimeAdd(accumulatedScreenPause, CMTimeSubtract(timestamp, pauseStart))
                pauseStartScreenTime = nil
            }
            if firstScreenTime == nil {
                firstScreenTime = timestamp
            }
            let adjustedTime = CMTimeSubtract(CMTimeSubtract(timestamp, firstScreenTime!), accumulatedScreenPause)
            lock.unlock()
            handleScreenSample(sampleBuffer, adjustedTime: adjustedTime)

        case .audio:
            if paused {
                if pauseStartAudioTime == nil {
                    pauseStartAudioTime = timestamp
                }
                lock.unlock()
                return
            }
            if let pauseStart = pauseStartAudioTime {
                accumulatedAudioPause = CMTimeAdd(accumulatedAudioPause, CMTimeSubtract(timestamp, pauseStart))
                pauseStartAudioTime = nil
            }
            if firstAudioTime == nil {
                firstAudioTime = timestamp
            }
            let adjustedTime = CMTimeSubtract(CMTimeSubtract(timestamp, firstAudioTime!), accumulatedAudioPause)
            lock.unlock()
            handleSystemAudioSample(sampleBuffer, adjustedTime: adjustedTime)

        case .microphone:
            lock.unlock()

        @unknown default:
            lock.unlock()
        }
    }

    private func handleScreenSample(_ sampleBuffer: CMSampleBuffer, adjustedTime: CMTime) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        lastVideoBuffer = sampleBuffer
        lastWriteTime = adjustedTime
        lock.unlock()

        // A compositing failure falls through to the raw frame: a recording
        // missing its bubble is far better than a dropped frame.
        var frame = pixelBuffer
        if let compositor, let cameraFrame = camera?.latestPixelBuffer,
           let composited = compositor.composite(screen: pixelBuffer, camera: cameraFrame) {
            frame = composited
        }

        videoWriter.appendPixelBuffer(frame, at: adjustedTime)
    }

    /// The last frame written, composited if this is a window capture, so the
    /// tail frame matches the rest of the recording.
    private func compositedLastFrame(_ pixelBuffer: CVPixelBuffer) -> CVPixelBuffer {
        guard let compositor, let cameraFrame = camera?.latestPixelBuffer,
              let composited = compositor.composite(screen: pixelBuffer, camera: cameraFrame) else {
            return pixelBuffer
        }
        return composited
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer, adjustedTime: CMTime) {
        // Track system audio activity for meeting auto-stop (throttled to once per second)
        let now = Date()
        if now.timeIntervalSince(Self.lastRMSCheckTime) >= 1.0 {
            Self.lastRMSCheckTime = now
            if Self.calculateRMS(sampleBuffer) > 0.001 {
                AudioActivityTracker.shared.recordActivity()
            }
        }

        if let retimed = AudioSampleTiming.retime(sampleBuffer, to: adjustedTime) {
            videoWriter.appendSystemAudioSample(retimed)
        }
    }

    private static func calculateRMS(_ sampleBuffer: CMSampleBuffer) -> Float {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return 0 }
        let length = CMBlockBufferGetDataLength(dataBuffer)
        guard length > 0 else { return 0 }

        var dataPointer: UnsafeMutablePointer<Int8>?
        var lengthAtOffset: Int = 0
        let status = CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: &lengthAtOffset, totalLengthOut: nil, dataPointerOut: &dataPointer)
        guard status == noErr, let ptr = dataPointer else { return 0 }

        let floatCount = lengthAtOffset / MemoryLayout<Float32>.size
        guard floatCount > 0 else { return 0 }

        return ptr.withMemoryRebound(to: Float32.self, capacity: floatCount) { floatPtr in
            var sumSquares: Float = 0
            for i in 0..<floatCount {
                let sample = floatPtr[i]
                sumSquares += sample * sample
            }
            return sqrtf(sumSquares / Float(floatCount))
        }
    }

    public func duplicateLastFrameIfNeeded() {
        lock.lock()
        guard let lastBuffer = lastVideoBuffer else { lock.unlock(); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(lastBuffer) else { lock.unlock(); return }
        let finalTime = CMTimeAdd(lastWriteTime, CMTime(value: 1, timescale: 60))
        lock.unlock()
        videoWriter.appendPixelBuffer(compositedLastFrame(pixelBuffer), at: finalTime)
    }

}
