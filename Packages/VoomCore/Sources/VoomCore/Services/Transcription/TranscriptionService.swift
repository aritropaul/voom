import Foundation
@preconcurrency import AVFoundation
import os
import FluidAudio

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

    private nonisolated(unsafe) var asrManager: AsrManager?
    private var isModelLoaded = false

    public func loadModel() async throws {
        guard !isModelLoaded else { return }

        logger.notice("[Voom] Loading FluidAudio ASR models...")
        let models = try await AsrModels.downloadAndLoad()
        let manager = AsrManager()
        try await manager.initialize(models: models)
        self.asrManager = manager
        isModelLoaded = true
        logger.notice("[Voom] FluidAudio ASR models loaded successfully")
    }

    public func transcribe(audioURL: URL) async throws -> [VoomTranscriptSegment] {
        if !isModelLoaded {
            try await loadModel()
        }

        guard let asrManager else {
            throw TranscriptionError.modelNotLoaded
        }

        logger.notice("[Voom] Starting transcription: \(audioURL.lastPathComponent)")
        let result = try await asrManager.transcribe(audioURL)
        logger.notice("[Voom] Transcription complete: \(result.text.count) chars, \(result.tokenTimings?.count ?? 0) tokens")

        let segments = segmentsFromTokenTimings(result)
        logger.notice("[Voom] Extracted \(segments.count) transcript segments")
        return segments
    }

    // MARK: - Token Grouping

    /// Group token-level timings into sentence-like segments.
    /// Breaks at sentence-ending punctuation, time gaps > 1.5s, or after ~30 words.
    private func segmentsFromTokenTimings(_ result: ASRResult) -> [VoomTranscriptSegment] {
        guard let timings = result.tokenTimings, !timings.isEmpty else {
            // No token timings — return entire text as one segment
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return [] }
            return [VoomTranscriptSegment(startTime: 0, endTime: result.duration, text: text)]
        }

        var segments: [VoomTranscriptSegment] = []
        var currentTokens: [TokenTiming] = []

        for (i, token) in timings.enumerated() {
            currentTokens.append(token)

            let isLast = i == timings.count - 1
            let endsWithPunctuation = token.token.hasSuffix(".") || token.token.hasSuffix("?") || token.token.hasSuffix("!")
            let hasTimeGap = !isLast && (timings[i + 1].startTime - token.endTime) > 1.5
            let tooManyWords = currentTokens.count >= 30

            if isLast || endsWithPunctuation || hasTimeGap || tooManyWords {
                let text = currentTokens.map(\.token).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(VoomTranscriptSegment(
                        startTime: currentTokens.first!.startTime,
                        endTime: currentTokens.last!.endTime,
                        text: text
                    ))
                }
                currentTokens = []
            }
        }

        return segments
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
