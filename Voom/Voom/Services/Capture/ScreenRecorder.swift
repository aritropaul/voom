import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreImage

actor ScreenRecorder {
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var videoWriter: VideoWriter?
    private var cameraCapture: CameraCapture?
    private let appState: AppState
    private var isPaused = false
    private var hadWebcam = false
    private var hadSystemAudio = false
    private var hadMicAudio = false
    private var ownsCamera = false
    private var micTimeAdjuster: MicTimeAdjuster?

    init(appState: AppState) {
        self.appState = appState
    }

    func startRecording(
        display: SCDisplay,
        cameraEnabled: Bool,
        micEnabled: Bool,
        systemAudioEnabled: Bool,
        pipPosition: PiPPosition,
        existingCamera: CameraCapture? = nil
    ) async throws {
        self.hadWebcam = cameraEnabled
        self.hadSystemAudio = systemAudioEnabled
        self.hadMicAudio = micEnabled

        let storage = RecordingStorage.shared
        let outputURL = await storage.newRecordingURL()

        // Configure screen capture — exclude Voom's own windows EXCEPT the camera PiP
        // The camera PiP window is captured directly so what you see = what you record
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let voomApp = shareableContent.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter: SCContentFilter

        // Find the camera PiP window to include it in the capture
        var exceptWindows: [SCWindow] = []
        if cameraEnabled {
            let pipWindowNumber = await MainActor.run { OverlayManager.shared.cameraPanelWindowNumber }
            if let pipWindowNumber,
               let pipSCWindow = shareableContent.windows.first(where: { $0.windowID == CGWindowID(pipWindowNumber) }) {
                exceptWindows.append(pipSCWindow)
            }
        }

        if let voomApp {
            filter = SCContentFilter(display: display, excludingApplications: [voomApp], exceptingWindows: exceptWindows)
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()

        // Capture at native Retina resolution using scaleFactor
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
        } ?? NSScreen.main
        let scaleFactor = Int(screen?.backingScaleFactor ?? 2)
        let finalWidth = (display.width * scaleFactor) & ~1
        let finalHeight = (display.height * scaleFactor) & ~1

        config.width = finalWidth
        config.height = finalHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = systemAudioEnabled
        config.sampleRate = 48000
        config.channelCount = 2

        // Set up camera reference (for mic capture) — no compositor needed
        // The camera PiP window is captured directly by SCStream
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

        // Create stream output handler — no compositor, screen capture includes the PiP window
        let output = StreamOutput(
            videoWriter: writer
        )

        // Set up mic capture if enabled — mic handler checks pause state via output
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
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        if systemAudioEnabled {
            try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        }

        try await stream.startCapture()
        self.stream = stream

        await MainActor.run {
            self.appState.currentRecordingURL = outputURL
        }
    }

    func stopRecording() async -> UUID? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        if ownsCamera, let camera = cameraCapture {
            await camera.stopCapture()
        }
        cameraCapture = nil
        ownsCamera = false

        if let writer = videoWriter, let output = streamOutput {
            output.duplicateLastFrameIfNeeded()
            await writer.finalize()
        }
        videoWriter = nil
        streamOutput = nil
        micTimeAdjuster = nil

        let outputURL = await MainActor.run { appState.currentRecordingURL }
        if let outputURL {
            return await saveRecording(
                at: outputURL,
                hasWebcam: hadWebcam,
                hasSystemAudio: hadSystemAudio,
                hasMicAudio: hadMicAudio
            )
        }
        return nil
    }

    func pause() {
        isPaused = true
        streamOutput?.isPaused = true
        micTimeAdjuster?.notifyPause()
    }

    func resume() {
        isPaused = false
        micTimeAdjuster?.notifyResume()
        streamOutput?.isPaused = false
    }

    private func saveRecording(at url: URL, hasWebcam: Bool, hasSystemAudio: Bool, hasMicAudio: Bool) async -> UUID {
        let storage = RecordingStorage.shared
        let duration = await storage.videoDuration(at: url)
        let resolution = await storage.videoResolution(at: url)
        let fileSize = await storage.fileSize(at: url)

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

        let thumbURL = await storage.generateThumbnail(for: url, recordingID: recording.id)
        recording.thumbnailURL = thumbURL

        let recordingID = recording.id
        await MainActor.run {
            RecordingStore.shared.add(recording)
        }

        // Auto-transcribe in background if audio is available and setting is enabled
        let autoTranscribe = UserDefaults.standard.object(forKey: "AutoTranscribe") == nil ? true : UserDefaults.standard.bool(forKey: "AutoTranscribe")
        if autoTranscribe && (hasSystemAudio || hasMicAudio) {
            let capturedURL = url
            let capturedID = recordingID
            Task.detached {
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.isTranscribing = true
                        RecordingStore.shared.update(rec)
                    }
                }
                do {
                    NSLog("[Voom] Auto-transcription starting for %@", capturedURL.lastPathComponent)
                    let segments = try await TranscriptionService.shared.transcribe(audioURL: capturedURL)
                    NSLog("[Voom] Auto-transcription got %d segments", segments.count)
                    await MainActor.run {
                        if var rec = RecordingStore.shared.recording(for: capturedID) {
                            rec.transcriptSegments = segments.map {
                                TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
                            }
                            rec.isTranscribed = !segments.isEmpty
                            rec.isTranscribing = false
                            RecordingStore.shared.update(rec)
                        }
                    }
                } catch {
                    NSLog("[Voom] Auto-transcription failed: %@", "\(error)")
                    await MainActor.run {
                        if var rec = RecordingStore.shared.recording(for: capturedID) {
                            rec.isTranscribing = false
                            RecordingStore.shared.update(rec)
                        }
                    }
                }
            }
        }

        return recordingID
    }
}

// MARK: - MicTimeAdjuster

final class MicTimeAdjuster: @unchecked Sendable {
    private var firstTime: CMTime?
    private var pauseStartTime: CMTime?
    private var accumulatedPause: CMTime = .zero
    private let lock = NSLock()

    func notifyPause() {
        lock.lock()
        if pauseStartTime == nil, let first = firstTime {
            // We'll calculate pause start on the next sample after resume
            // For now just mark that we're paused
            pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        lock.unlock()
    }

    func notifyResume() {
        lock.lock()
        if let pauseStart = pauseStartTime {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(now, pauseStart))
            pauseStartTime = nil
        }
        lock.unlock()
    }

    func retime(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock()
        if firstTime == nil {
            firstTime = timestamp
        }
        let base = firstTime!
        let pauseOffset = accumulatedPause
        lock.unlock()

        let adjusted = CMTimeSubtract(CMTimeSubtract(timestamp, base), pauseOffset)
        guard adjusted.seconds >= 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: adjusted,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }
}

// MARK: - StreamOutput

final class StreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let videoWriter: VideoWriter
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

    var isPaused: Bool {
        get { lock.withLock { _isPaused } }
        set {
            lock.lock()
            if newValue && !_isPaused {
                // Starting pause — will record actual pause start on next sample
                _isPaused = true
                pauseStartScreenTime = nil
                pauseStartAudioTime = nil
            } else if !newValue && _isPaused {
                // Resuming — pause end will be calculated on next sample
                _isPaused = false
            }
            lock.unlock()
        }
    }

    init(videoWriter: VideoWriter) {
        self.videoWriter = videoWriter
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
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
            // If resuming from pause, accumulate the paused duration
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

        videoWriter.appendPixelBuffer(pixelBuffer, at: adjustedTime)
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer, adjustedTime: CMTime) {
        if let retimed = retimeSampleBuffer(sampleBuffer, to: adjustedTime) {
            videoWriter.appendSystemAudioSample(retimed)
        }
    }

    func duplicateLastFrameIfNeeded() {
        lock.lock()
        guard let lastBuffer = lastVideoBuffer else { lock.unlock(); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(lastBuffer) else { lock.unlock(); return }
        let finalTime = CMTimeAdd(lastWriteTime, CMTime(value: 1, timescale: 60))
        lock.unlock()
        videoWriter.appendPixelBuffer(pixelBuffer, at: finalTime)
    }

    private func retimeSampleBuffer(_ buffer: CMSampleBuffer, to time: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }
}
