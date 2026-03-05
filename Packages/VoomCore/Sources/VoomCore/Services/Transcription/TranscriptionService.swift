import Foundation
@preconcurrency import AVFoundation
import os
#if canImport(WhisperKit)
@preconcurrency import WhisperKit
#endif

private let logger = Logger(subsystem: "com.voom.app", category: "Transcription")

public struct VoomTranscriptSegment: Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

public actor TranscriptionService {
    public static let shared = TranscriptionService()

    #if canImport(WhisperKit)
    private nonisolated(unsafe) var whisperKit: WhisperKit?
    #endif
    private var isModelLoaded = false

    public func loadModel() async throws {
        guard !isModelLoaded else { return }

        #if canImport(WhisperKit)
        logger.notice("[Voom] Loading WhisperKit model...")
        let config = WhisperKitConfig(
            model: "distil-large-v3",
            verbose: true,
            logLevel: .debug,
            prewarm: true,
            load: true
        )
        whisperKit = try await WhisperKit(config)
        isModelLoaded = true
        logger.notice("[Voom] WhisperKit model loaded successfully")
        #else
        throw TranscriptionError.whisperKitNotAvailable
        #endif
    }

    public func transcribe(audioURL: URL) async throws -> [VoomTranscriptSegment] {
        #if canImport(WhisperKit)
        if !isModelLoaded {
            try await loadModel()
        }

        guard let whisperKit else {
            throw TranscriptionError.modelNotLoaded
        }

        logger.notice("[Voom] Extracting audio from: \(audioURL.lastPathComponent)")
        let wavURL = try await extractAudio(from: audioURL)
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: wavURL.path(percentEncoded: false))[.size] as? Int64) ?? 0
        logger.notice("[Voom] Audio extracted: \(wavURL.lastPathComponent), size: \(fileSize) bytes")

        let result: [TranscriptionResult]
        do {
            logger.notice("[Voom] Starting transcription...")
            result = try await whisperKit.transcribe(audioPath: wavURL.path())
            logger.notice("[Voom] Transcription complete: \(result.count) result(s)")
        } catch {
            logger.error("[Voom] Transcription error: \(error)")
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
        logger.notice("[Voom] Extracted \(segments.count) transcript segments")
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
        logger.notice("[Voom] Source duration: \(duration.seconds, format: .fixed(precision: 1))s, audio tracks: \(audioTracks.count)")

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
            logger.error("[Voom] M4A export failed: \(exportSession.error?.localizedDescription ?? "unknown")")
            throw TranscriptionError.audioExtractionFailed
        }

        let audioFile = try AVAudioFile(forReading: m4aURL)
        logger.notice("[Voom] M4A: rate=\(audioFile.processingFormat.sampleRate, format: .fixed(precision: 0)), ch=\(audioFile.processingFormat.channelCount), frames=\(audioFile.length)")

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

        let frameCount = AVAudioFrameCount(audioFile.length)
        let srcBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: frameCount)!
        try audioFile.read(into: srcBuffer)

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
            logger.error("[Voom] Conversion error: \(convError.localizedDescription)")
        }

        logger.notice("[Voom] Converted: \(frameCount) frames -> \(dstBuffer.frameLength) frames (\(Double(dstBuffer.frameLength) / 16000.0, format: .fixed(precision: 1))s)")

        if dstBuffer.frameLength > 0 {
            try wavFile.write(from: dstBuffer)
        }

        try? FileManager.default.removeItem(at: m4aURL)
        return wavURL
    }
}

public enum TranscriptionError: LocalizedError {
    case whisperKitNotAvailable
    case modelNotLoaded
    case audioExtractionFailed
    case noAudioTrack

    public var errorDescription: String? {
        switch self {
        case .whisperKitNotAvailable: "WhisperKit is not available"
        case .modelNotLoaded: "Transcription model not loaded"
        case .audioExtractionFailed: "Failed to extract audio"
        case .noAudioTrack: "No audio track found in recording"
        }
    }
}
