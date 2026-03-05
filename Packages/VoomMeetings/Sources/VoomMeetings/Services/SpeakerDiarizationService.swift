import Foundation
import os
import FluidAudio

private let logger = Logger(subsystem: "com.voom.app", category: "SpeakerDiarization")

public struct SpeakerSegment: Sendable {
    public let speaker: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
}

public actor SpeakerDiarizationService {
    public static let shared = SpeakerDiarizationService()
    private init() {}

    private nonisolated(unsafe) var mixedManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var remoteManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var localManager: OfflineDiarizerManager?

    /// Prepare diarization models with meeting-optimized config for mixed audio fallback.
    public func prepareModels() async throws {
        guard mixedManager == nil else { return }
        logger.notice("[Voom] Preparing speaker diarization models...")
        let config = OfflineDiarizerConfig(clusteringThreshold: 0.45)
            .withSpeakers(min: 2)
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()
        self.mixedManager = mgr
        logger.notice("[Voom] Speaker diarization models ready (mixed, threshold=0.45, minSpeakers=2)")
    }

    /// Prepare the remote speaker manager (system audio only, default threshold, no speaker constraint).
    private func prepareRemoteManager() async throws {
        guard remoteManager == nil else { return }
        let config = OfflineDiarizerConfig(clusteringThreshold: 0.6)
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()
        self.remoteManager = mgr
        logger.notice("[Voom] Remote speaker diarization models ready (threshold=0.6)")
    }

    /// Prepare the local speaker manager (mic audio, forced single speaker).
    private func prepareLocalManager() async throws {
        guard localManager == nil else { return }
        let config = OfflineDiarizerConfig(clusteringThreshold: 0.6)
            .withSpeakers(min: 1, max: 1)
        let mgr = OfflineDiarizerManager(config: config)
        try await mgr.prepareModels()
        self.localManager = mgr
        logger.notice("[Voom] Local speaker diarization models ready (numSpeakers=1)")
    }

    /// Run speaker diarization on mixed audio (fallback path).
    public func diarize(url: URL) async throws -> [SpeakerSegment] {
        if mixedManager == nil {
            try await prepareModels()
        }
        guard let mixedManager else {
            logger.error("[Voom] Diarization manager not available")
            return []
        }

        logger.notice("[Voom] Starting mixed speaker diarization: \(url.lastPathComponent)")
        let result = try await mixedManager.process(url)
        return mapSegments(result)
    }

    /// Diarize system-only audio to identify remote speakers.
    /// Returns segments labeled "Speaker 1", "Speaker 2", etc.
    public func diarizeRemoteSpeakers(systemAudioURL: URL) async throws -> [SpeakerSegment] {
        try await prepareRemoteManager()
        guard let remoteManager else {
            logger.error("[Voom] Remote diarization manager not available")
            return []
        }

        logger.notice("[Voom] Diarizing remote speakers: \(systemAudioURL.lastPathComponent)")
        let result = try await remoteManager.process(systemAudioURL)
        return mapSegments(result)
    }

    /// Diarize mic-only audio to identify when the local user is speaking.
    /// Returns time segments for "You".
    public func diarizeLocalSpeaker(micAudioURL: URL) async throws -> [SpeakerSegment] {
        try await prepareLocalManager()
        guard let localManager else {
            logger.error("[Voom] Local diarization manager not available")
            return []
        }

        logger.notice("[Voom] Diarizing local speaker: \(micAudioURL.lastPathComponent)")
        let result = try await localManager.process(micAudioURL)

        // All segments from mic are "You"
        return result.segments.map { segment in
            SpeakerSegment(
                speaker: "You",
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds)
            )
        }
    }

    /// Map raw diarization result to sequential "Speaker 1", "Speaker 2", etc.
    private func mapSegments(_ result: DiarizationResult) -> [SpeakerSegment] {
        var speakerMap: [String: String] = [:]
        var nextSpeaker = 1
        var segments: [SpeakerSegment] = []

        for segment in result.segments {
            if speakerMap[segment.speakerId] == nil {
                speakerMap[segment.speakerId] = "Speaker \(nextSpeaker)"
                nextSpeaker += 1
            }

            segments.append(SpeakerSegment(
                speaker: speakerMap[segment.speakerId]!,
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds)
            ))
        }

        logger.notice("[Voom] Diarization complete: \(segments.count) segments, \(speakerMap.count) speakers")
        return segments
    }
}
