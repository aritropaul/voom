import Foundation
@preconcurrency import AVFoundation
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

struct VoomTranscriptSegment: Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

actor TranscriptionService {
    static let shared = TranscriptionService()

    #if canImport(WhisperKit)
    private nonisolated(unsafe) var whisperKit: WhisperKit?
    #endif
    private var isModelLoaded = false

    func loadModel() async throws {
        guard !isModelLoaded else { return }

        #if canImport(WhisperKit)
        NSLog("[Voom] Loading WhisperKit model...")
        let config = WhisperKitConfig(
            model: "distil-large-v3",
            verbose: true,
            logLevel: .debug,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(config)
        isModelLoaded = true
        NSLog("[Voom] WhisperKit model loaded successfully")
        #else
        throw TranscriptionError.whisperKitNotAvailable
        #endif
    }

    func transcribe(audioURL: URL) async throws -> [VoomTranscriptSegment] {
        #if canImport(WhisperKit)
        if !isModelLoaded {
            try await loadModel()
        }

        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        NSLog("[Voom] Extracting audio from: %@", audioURL.lastPathComponent)
        let wavURL = try await extractAudio(from: audioURL)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path)[.size] as? Int64) ?? 0
        NSLog("[Voom] Audio extracted: %@, size: %lld bytes", wavURL.lastPathComponent, fileSize)

        let result: [TranscriptionResult]
        do {
            NSLog("[Voom] Starting transcription...")
            result = try await whisperKit.transcribe(audioPath: wavURL.path())
            NSLog("[Voom] Transcription complete: %d result(s)", result.count)
        } catch {
            NSLog("[Voom] Transcription error: %@", "\(error)")
            try? FileManager.default.removeItem(at: wavURL)
            throw error
        }
        try? FileManager.default.removeItem(at: wavURL)

        let segments = result.flatMap { transcriptionResult in
            transcriptionResult.segments.compactMap { segment -> VoomTranscriptSegment? in
                let cleaned = cleanTranscriptText(segment.text)
                guard !cleaned.isEmpty else { return nil }
                return VoomTranscriptSegment(
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end),
                    text: cleaned
                )
            }
        }
        NSLog("[Voom] Extracted %d transcript segments", segments.count)
        return segments
        #else
        throw TranscriptionError.whisperKitNotAvailable
        #endif
    }

    private func cleanTranscriptText(_ text: String) -> String {
        var cleaned = text.replacingOccurrences(
            of: "<\\|[^|]*\\|>",
            with: "",
            options: .regularExpression
        )
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }

    private func extractAudio(from videoURL: URL) async throws -> URL {
        let asset = AVURLAsset(url: videoURL)
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscriptionError.noAudioTrack
        }
        let duration = try await asset.load(.duration)
        NSLog("[Voom] Source duration: %.1fs, audio tracks: %d", duration.seconds, audioTracks.count)

        // Step 1: Export audio to M4A using AVAssetExportSession
        let m4aURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("m4a")

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.audioExtractionFailed
        }
        exportSession.outputURL = m4aURL
        exportSession.outputFileType = .m4a
        exportSession.timeRange = CMTimeRange(start: .zero, duration: duration)
        await exportSession.export()

        guard exportSession.status == .completed else {
            NSLog("[Voom] M4A export failed: %@", exportSession.error?.localizedDescription ?? "unknown")
            throw TranscriptionError.audioExtractionFailed
        }

        // Step 2: Convert M4A to 16kHz mono float32 WAV
        let audioFile = try AVAudioFile(forReading: m4aURL)
        NSLog("[Voom] M4A: rate=%.0f, ch=%d, frames=%lld", audioFile.processingFormat.sampleRate, audioFile.processingFormat.channelCount, audioFile.length)

        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!

        let wavFile = try AVAudioFile(
            forWriting: wavURL,
            settings: targetFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        guard let converter = AVAudioConverter(from: audioFile.processingFormat, to: targetFormat) else {
            try? FileManager.default.removeItem(at: m4aURL)
            throw TranscriptionError.audioExtractionFailed
        }

        // Read entire source into one buffer
        let frameCount = AVAudioFrameCount(audioFile.length)
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
        try audioFile.read(into: srcBuffer)

        // Convert in one pass with proper input block
        let ratio = targetFormat.sampleRate / audioFile.processingFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(frameCount) * ratio) + 100
        let dstBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount)!

        var inputProvided = false
        var convError: NSError?
        converter.convert(to: dstBuffer, error: &convError) { _, outStatus in
            if inputProvided {
                outStatus.pointee = .endOfStream
                return nil
            }
            inputProvided = true
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if let convError {
            NSLog("[Voom] Conversion error: %@", convError.localizedDescription)
        }

        NSLog("[Voom] Converted: %d frames -> %d frames (%.1fs)", frameCount, dstBuffer.frameLength, Double(dstBuffer.frameLength) / 16000.0)

        if dstBuffer.frameLength > 0 {
            try wavFile.write(from: dstBuffer)
        }

        try? FileManager.default.removeItem(at: m4aURL)
        return wavURL
    }
}

enum TranscriptionError: LocalizedError {
    case whisperKitNotAvailable
    case modelNotLoaded
    case audioExtractionFailed
    case noAudioTrack

    var errorDescription: String? {
        switch self {
        case .whisperKitNotAvailable: "WhisperKit is not available"
        case .modelNotLoaded: "Transcription model not loaded"
        case .audioExtractionFailed: "Failed to extract audio"
        case .noAudioTrack: "No audio track found in recording"
        }
    }
}
