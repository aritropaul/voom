import Foundation
@preconcurrency import AVFoundation
import CoreML
import os
import FluidAudio

private let logger = Logger(subsystem: "com.voom.app", category: "Transcription")

public struct VoomTranscriptSegment: Sendable {
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let text: String
    public let speaker: String?

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

public actor TranscriptionService {
    public static let shared = TranscriptionService()

    private nonisolated(unsafe) var asrManager: AsrManager?
    private var loadTask: Task<AsrManager, Error>?

    public func loadModel() async throws {
        _ = try await manager()
    }

    /// Return the resident manager, loading the models if needed.
    /// Concurrent callers share a single load instead of each compiling their own copy.
    private func manager() async throws -> AsrManager {
        if let asrManager { return asrManager }
        if let loadTask { return try await loadTask.value }

        logger.notice("[Voom] Loading FluidAudio ASR models...")
        let task = Task<AsrManager, Error> {
            let models = try await AsrModels.downloadAndLoad()
            return AsrManager(models: models)
        }
        loadTask = task
        defer { loadTask = nil }

        let manager = try await task.value
        asrManager = manager
        logger.notice("[Voom] FluidAudio ASR models loaded successfully")
        return manager
    }

    public func transcribe(audioURL: URL) async throws -> [VoomTranscriptSegment] {
        let segments = TranscriptSegmenter.segments(from: try await transcribeTokens(audioURL: audioURL))
        logger.notice("[Voom] Extracted \(segments.count) transcript segments")
        return segments
    }

    /// Transcribe to token-level timings, for callers that attribute speakers per word.
    public func transcribeTokens(audioURL: URL) async throws -> [VoomTranscriptToken] {
        let hadResidentModels = asrManager != nil
        do {
            return try await runTranscription(audioURL: audioURL)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // CoreML can invalidate models that have been resident for a long time —
            // macOS purges the compiled ANE bundle cache out from under the process —
            // and from then on every prediction fails instantly. Models we just loaded
            // aren't suspect; long-resident ones that fail inside CoreML are, so drop
            // them and give the transcription one fresh attempt.
            guard hadResidentModels, error.isCoreMLFailure else { throw error }
            logger.error("[Voom] Transcription failed on resident ASR models (\(error.localizedDescription)); reloading models and retrying once")
            // Released rather than cleaned up: a transcription already in flight keeps
            // its own reference to the old manager and finishes on it.
            asrManager = nil
            return try await runTranscription(audioURL: audioURL)
        }
    }

    private func runTranscription(audioURL: URL) async throws -> [VoomTranscriptToken] {
        let asrManager = try await manager()

        logger.notice("[Voom] Starting transcription: \(audioURL.lastPathComponent)")
        // FluidAudio 0.15: transcribe drives an explicit, caller-owned TDT decoder state.
        var decoderState = try TdtDecoderState(decoderLayers: await asrManager.decoderLayerCount)
        let result = try await asrManager.transcribe(audioURL, decoderState: &decoderState)
        logger.notice("[Voom] Transcription complete: \(result.text.count) chars, \(result.tokenTimings?.count ?? 0) tokens")

        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No token timings — the entire text becomes one token spanning the file
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [VoomTranscriptToken(text: text, startTime: 0, endTime: result.duration)]
        }
        return timings.map { VoomTranscriptToken(text: $0.token, startTime: $0.startTime, endTime: $0.endTime) }
    }
}

extension Error {
    /// True when this error, or an error it wraps, came from CoreML — the signature of
    /// models that have been invalidated underneath a long-lived process.
    var isCoreMLFailure: Bool {
        var candidate = self as NSError
        while true {
            if candidate.domain == MLModelErrorDomain { return true }
            guard let underlying = candidate.userInfo[NSUnderlyingErrorKey] as? NSError else { return false }
            candidate = underlying
        }
    }
}

public enum TranscriptionError: LocalizedError {
    case modelNotLoaded
    case audioExtractionFailed
    case noAudioTrack

    public var errorDescription: String? {
        switch self {
        case .modelNotLoaded: "Transcription model not loaded"
        case .audioExtractionFailed: "Failed to extract audio"
        case .noAudioTrack: "No audio track found in recording"
        }
    }
}
