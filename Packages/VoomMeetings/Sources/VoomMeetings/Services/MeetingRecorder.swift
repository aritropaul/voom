import Foundation
@preconcurrency import ScreenCaptureKit
import AVFoundation
import AppKit
import VoomCore

// MARK: - AudioReferenceWriter

/// Writes audio-only M4A to a temp file for post-recording diarization.
public final class AudioReferenceWriter: @unchecked Sendable {
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private let outputURL: URL
    private let lock = NSLock()
    private var started = false

    public init(outputURL: URL, channelCount: Int, sampleRate: Int) {
        self.outputURL = outputURL
        do {
            let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
            let settings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channelCount,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            writer.add(input)
            self.assetWriter = writer
            self.audioInput = input
        } catch {
            self.assetWriter = nil
            self.audioInput = nil
        }
    }

    public func appendSample(_ buffer: CMSampleBuffer) {
        lock.lock()
        guard let writer = assetWriter, let input = audioInput else { lock.unlock(); return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(buffer))
            started = true
        }
        if input.isReadyForMoreMediaData {
            input.append(buffer)
        }
        lock.unlock()
    }

    public func finalize() async {
        let writer: AVAssetWriter? = lock.withLock {
            guard let w = assetWriter, started else { return nil }
            return w
        }
        guard let writer else { return }
        await withCheckedContinuation { continuation in
            writer.finishWriting {
                continuation.resume()
            }
        }
    }
}

/// Meeting-specific recorder: 30fps, HD/2K, single mixed audio track,
/// no camera PiP, no annotations, no region selection.
public actor MeetingRecorder {
    private var stream: SCStream?
    private var streamOutput: MeetingStreamOutput?
    private var videoWriter: VideoWriter?
    private var cameraCapture: CameraCapture?
    private var micTimeAdjuster: MeetingMicTimeAdjuster?
    private let stateProvider: any RecordingStateProvider
    private var isPaused = false
    private var micRefWriter: AudioReferenceWriter?
    private var systemRefWriter: AudioReferenceWriter?
    private var micReferenceURL: URL?
    private var systemReferenceURL: URL?

    public init(stateProvider: any RecordingStateProvider) {
        self.stateProvider = stateProvider
    }

    public func startRecording(
        display: SCDisplay,
        micEnabled: Bool
    ) async throws {
        let storage = RecordingStorage.shared
        let outputURL = await storage.newRecordingURL()

        // Configure screen capture — exclude Voom's own windows entirely (no PiP)
        let shareableContent = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let voomApp = shareableContent.applications.first { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter: SCContentFilter
        if let voomApp {
            filter = SCContentFilter(display: display, excludingApplications: [voomApp], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }

        let config = SCStreamConfiguration()

        // Meeting quality: HD/2K at 30fps (downscale from retina)
        let scaleFactor: Int = await MainActor.run {
            let screen = NSScreen.screens.first {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
            } ?? NSScreen.main
            return Int(screen?.backingScaleFactor ?? 2)
        }

        // Cap at 2K (2560x1440) for meeting recordings
        let nativeWidth = display.width * scaleFactor
        let nativeHeight = display.height * scaleFactor
        let maxDimension = 2560
        if nativeWidth > maxDimension || nativeHeight > maxDimension {
            let scale = Double(maxDimension) / Double(max(nativeWidth, nativeHeight))
            config.width = (Int(Double(nativeWidth) * scale)) & ~1
            config.height = (Int(Double(nativeHeight) * scale)) & ~1
        } else {
            config.width = nativeWidth & ~1
            config.height = nativeHeight & ~1
        }

        config.minimumFrameInterval = CMTime(value: 1, timescale: 30) // 30fps
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = true // system audio always on for meetings
        config.sampleRate = 48000
        config.channelCount = 2

        // Set up video writer with single mixed audio track
        let writer = VideoWriter()
        try writer.configure(
            outputURL: outputURL,
            width: config.width,
            height: config.height,
            hasSystemAudio: true,
            hasMicAudio: micEnabled,
            preset: .meeting
        )
        self.videoWriter = writer

        // Set up audio reference writers for split-track diarization
        let tempDir = FileManager.default.temporaryDirectory
        let systemRefURL = tempDir.appendingPathComponent("voom-system-\(UUID().uuidString).m4a")
        let sysWriter = AudioReferenceWriter(outputURL: systemRefURL, channelCount: 2, sampleRate: 48000)
        self.systemRefWriter = sysWriter
        self.systemReferenceURL = systemRefURL

        // Create stream output handler with system ref writer
        let output = MeetingStreamOutput(videoWriter: writer, systemRefWriter: sysWriter)
        self.streamOutput = output

        // Set up mic capture if enabled
        if micEnabled {
            let micRefURL = tempDir.appendingPathComponent("voom-mic-\(UUID().uuidString).m4a")
            let micWriter = AudioReferenceWriter(outputURL: micRefURL, channelCount: 1, sampleRate: 48000)
            self.micRefWriter = micWriter
            self.micReferenceURL = micRefURL

            let writerRef = writer
            let micTimer = MeetingMicTimeAdjuster()
            self.micTimeAdjuster = micTimer
            let outputRef = output
            let camera = CameraCapture()
            self.cameraCapture = camera
            try await camera.startMicCapture { sampleBuffer in
                guard !outputRef.isPaused else { return }
                if let retimed = micTimer.retime(sampleBuffer) {
                    writerRef.appendMicAudioSample(retimed)
                    micWriter.appendSample(retimed)
                }
            }
        }

        // Start capture
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: .global(qos: .userInteractive))
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))

        try await stream.startCapture()
        self.stream = stream

        await MainActor.run {
            self.stateProvider.currentRecordingURL = outputURL
        }
    }

    public func stopRecording() async -> UUID? {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil

        if let camera = cameraCapture {
            await camera.stopCapture()
        }
        cameraCapture = nil

        if let writer = videoWriter, let output = streamOutput {
            output.duplicateLastFrameIfNeeded()
            await writer.finalize()
        }
        videoWriter = nil
        streamOutput = nil
        micTimeAdjuster = nil

        // Finalize audio reference writers
        if let micRef = micRefWriter {
            await micRef.finalize()
        }
        if let sysRef = systemRefWriter {
            await sysRef.finalize()
        }
        micRefWriter = nil
        systemRefWriter = nil

        let outputURL = await MainActor.run { stateProvider.currentRecordingURL }
        if let outputURL {
            return await saveRecording(at: outputURL)
        }
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

    private func saveRecording(at url: URL) async -> UUID {
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
            hasWebcam: false,
            hasSystemAudio: true,
            hasMicAudio: cameraCapture != nil, // mic was enabled if camera exists
            recordingMode: .fullScreen,
            isMeeting: true
        )

        let thumbURL = await storage.generateThumbnail(for: url, recordingID: recording.id)
        recording.thumbnailURL = thumbURL

        let recordingID = recording.id
        await MainActor.run {
            RecordingStore.shared.add(recording)
        }

        // Auto-transcribe meetings with speaker diarization
        let autoTranscribeEnabled = UserDefaults.standard.object(forKey: "AutoTranscribe") == nil ? true : UserDefaults.standard.bool(forKey: "AutoTranscribe")
        if autoTranscribeEnabled {
            let capturedID = recordingID
            let capturedURL = url
            let capturedMicRef = micReferenceURL
            let capturedSysRef = systemReferenceURL
            Task.detached {
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.isTranscribing = true
                        RecordingStore.shared.update(rec)
                    }
                }

                // Run meeting-specific transcription with split-track diarization
                let segments = await MeetingTranscription.shared.transcribeMeeting(
                    fileURL: capturedURL,
                    micReferenceURL: capturedMicRef,
                    systemReferenceURL: capturedSysRef
                )

                // Generate meeting title, summary, and chapters from diarized transcript
                let title = await MeetingAnalysis.shared.generateMeetingTitle(from: segments)
                let summary = await MeetingAnalysis.shared.generateDetailedSummary(from: segments)
                let chapters = await TextAnalysisService.shared.generateChapters(from: segments)

                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.transcriptSegments = segments
                        if let title, !title.isEmpty { rec.title = title }
                        rec.summary = summary
                        if !chapters.isEmpty { rec.chapters = chapters }
                        rec.isTranscribed = !segments.isEmpty
                        rec.isTranscribing = false
                        RecordingStore.shared.update(rec)
                    }
                }

                // Clean up temp audio reference files
                if let micRef = capturedMicRef { try? FileManager.default.removeItem(at: micRef) }
                if let sysRef = capturedSysRef { try? FileManager.default.removeItem(at: sysRef) }
            }
        }

        return recordingID
    }
}

// MARK: - MeetingStreamOutput

public final class MeetingStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private let videoWriter: VideoWriter
    private let systemRefWriter: AudioReferenceWriter?
    private let lock = NSLock()

    private var firstScreenTime: CMTime?
    private var firstAudioTime: CMTime?
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastWriteTime: CMTime = .zero

    private var _isPaused = false
    private var pauseStartScreenTime: CMTime?
    private var pauseStartAudioTime: CMTime?
    private var accumulatedScreenPause: CMTime = .zero
    private var accumulatedAudioPause: CMTime = .zero

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

    public init(videoWriter: VideoWriter, systemRefWriter: AudioReferenceWriter? = nil) {
        self.videoWriter = videoWriter
        self.systemRefWriter = systemRefWriter
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sampleBuffer.isValid else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        lock.lock()
        let paused = _isPaused

        switch type {
        case .screen:
            if paused {
                if pauseStartScreenTime == nil { pauseStartScreenTime = timestamp }
                lock.unlock()
                return
            }
            if let pauseStart = pauseStartScreenTime {
                accumulatedScreenPause = CMTimeAdd(accumulatedScreenPause, CMTimeSubtract(timestamp, pauseStart))
                pauseStartScreenTime = nil
            }
            if firstScreenTime == nil { firstScreenTime = timestamp }
            let adjustedTime = CMTimeSubtract(CMTimeSubtract(timestamp, firstScreenTime!), accumulatedScreenPause)
            lock.unlock()
            handleScreenSample(sampleBuffer, adjustedTime: adjustedTime)

        case .audio:
            if paused {
                if pauseStartAudioTime == nil { pauseStartAudioTime = timestamp }
                lock.unlock()
                return
            }
            if let pauseStart = pauseStartAudioTime {
                accumulatedAudioPause = CMTimeAdd(accumulatedAudioPause, CMTimeSubtract(timestamp, pauseStart))
                pauseStartAudioTime = nil
            }
            if firstAudioTime == nil { firstAudioTime = timestamp }
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

        videoWriter.appendPixelBuffer(pixelBuffer, at: adjustedTime)
    }

    private func handleSystemAudioSample(_ sampleBuffer: CMSampleBuffer, adjustedTime: CMTime) {
        // Track audio activity for auto-stop
        AudioActivityTracker.shared.recordActivity()

        if let retimed = retimeSampleBuffer(sampleBuffer, to: adjustedTime) {
            videoWriter.appendSystemAudioSample(retimed)
            systemRefWriter?.appendSample(retimed)
        }
    }

    public func duplicateLastFrameIfNeeded() {
        lock.lock()
        guard let lastBuffer = lastVideoBuffer else { lock.unlock(); return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(lastBuffer) else { lock.unlock(); return }
        let finalTime = CMTimeAdd(lastWriteTime, CMTime(value: 1, timescale: 30))
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

// MARK: - MeetingMicTimeAdjuster

public final class MeetingMicTimeAdjuster: @unchecked Sendable {
    private var firstTime: CMTime?
    private var pauseStartTime: CMTime?
    private var accumulatedPause: CMTime = .zero
    private let lock = NSLock()

    public init() {}

    public func notifyPause() {
        lock.lock()
        if pauseStartTime == nil, let _ = firstTime {
            pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        lock.unlock()
    }

    public func notifyResume() {
        lock.lock()
        if let pauseStart = pauseStartTime {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(now, pauseStart))
            pauseStartTime = nil
        }
        lock.unlock()
    }

    public func retime(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock()
        if firstTime == nil { firstTime = timestamp }
        guard let base = firstTime else { lock.unlock(); return nil }
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
