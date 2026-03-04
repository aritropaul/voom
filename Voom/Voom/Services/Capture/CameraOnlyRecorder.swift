import Foundation
import AVFoundation

actor CameraOnlyRecorder {
    private var cameraCapture: CameraCapture?
    private var videoWriter: VideoWriter?
    private let appState: AppState
    private var isPaused = false
    private var hadMicAudio = false
    private var firstFrameTime: CMTime?
    private var accumulatedPause: CMTime = .zero
    private var pauseStartTime: CMTime?
    private let lock = NSLock()

    init(appState: AppState) {
        self.appState = appState
    }

    func startRecording(
        micEnabled: Bool,
        existingCamera: CameraCapture? = nil
    ) async throws {
        self.hadMicAudio = micEnabled

        let storage = RecordingStorage.shared
        let outputURL = await storage.newRecordingURL()

        // Set up camera
        let camera: CameraCapture
        if let existingCamera {
            camera = existingCamera
        } else {
            camera = CameraCapture()
            try await camera.startCapture()
        }
        self.cameraCapture = camera

        // Configure writer for camera resolution (720p)
        let width = 1280 & ~1
        let height = 720 & ~1

        let writer = VideoWriter()
        try writer.configure(
            outputURL: outputURL,
            width: width,
            height: height,
            hasSystemAudio: false,
            hasMicAudio: micEnabled
        )
        self.videoWriter = writer

        // Set up video frame handler
        let writerRef = writer
        let recorderRef = self

        // Get video frames from camera via delegate
        let frameHandler = CameraFrameRecordHandler(
            writer: writerRef,
            recorder: recorderRef
        )
        await camera.setVideoFrameHandler(frameHandler)

        // Set up mic capture if enabled
        if micEnabled {
            let micTimer = MicTimeAdjuster()
            try await camera.startMicCapture { [weak writerRef] sampleBuffer in
                guard let writer = writerRef else { return }
                if let retimed = micTimer.retime(sampleBuffer) {
                    writer.appendMicAudioSample(retimed)
                }
            }
        }

        await MainActor.run {
            self.appState.currentRecordingURL = outputURL
        }
    }

    func stopRecording() async -> UUID? {
        if let camera = cameraCapture {
            await camera.setVideoFrameHandler(nil)
        }

        if let writer = videoWriter {
            await writer.finalize()
        }
        videoWriter = nil

        let outputURL = await MainActor.run { appState.currentRecordingURL }
        if let outputURL {
            return await saveRecording(
                at: outputURL,
                hasMicAudio: hadMicAudio
            )
        }
        return nil
    }

    func pause() {
        isPaused = true
    }

    func resume() {
        isPaused = false
    }

    nonisolated func getIsPaused() -> Bool {
        // This is a simplified check - the actual pause state is managed by the actor
        false
    }

    func appendVideoFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard !isPaused else { return }
        videoWriter?.appendPixelBuffer(pixelBuffer, at: time)
    }

    private func saveRecording(at url: URL, hasMicAudio: Bool) async -> UUID {
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
            hasWebcam: true,
            hasSystemAudio: false,
            hasMicAudio: hasMicAudio,
            recordingMode: .cameraOnly
        )

        let thumbURL = await storage.generateThumbnail(for: url, recordingID: recording.id)
        recording.thumbnailURL = thumbURL

        let recordingID = recording.id
        await MainActor.run {
            RecordingStore.shared.add(recording)
        }

        // Auto-transcribe if audio available
        let autoTranscribeEnabled = UserDefaults.standard.object(forKey: "AutoTranscribe") == nil ? true : UserDefaults.standard.bool(forKey: "AutoTranscribe")
        if autoTranscribeEnabled && hasMicAudio {
            await MainActor.run {
                RecordingStore.shared.autoTranscribe(recordingID: recordingID, fileURL: url)
            }
        }

        return recordingID
    }
}

// MARK: - Camera Frame Record Handler

final class CameraFrameRecordHandler: @unchecked Sendable {
    private let writer: VideoWriter
    private let recorder: CameraOnlyRecorder
    private var firstTime: CMTime?
    private var pauseStart: CMTime?
    private var accumulatedPause: CMTime = .zero
    private var isPaused = false
    private let lock = NSLock()

    init(writer: VideoWriter, recorder: CameraOnlyRecorder) {
        self.writer = writer
        self.recorder = recorder
    }

    func handleFrame(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        if firstTime == nil {
            firstTime = time
        }
        guard let base = firstTime else { lock.unlock(); return }
        let pauseOffset = accumulatedPause
        lock.unlock()

        let adjusted = CMTimeSubtract(CMTimeSubtract(time, base), pauseOffset)
        guard adjusted.seconds >= 0 else { return }
        writer.appendPixelBuffer(pixelBuffer, at: adjusted)
    }

    func notifyPause() {
        lock.lock()
        isPaused = true
        pauseStart = CMClockGetTime(CMClockGetHostTimeClock())
        lock.unlock()
    }

    func notifyResume() {
        lock.lock()
        isPaused = false
        if let start = pauseStart {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(now, start))
            pauseStart = nil
        }
        lock.unlock()
    }
}

