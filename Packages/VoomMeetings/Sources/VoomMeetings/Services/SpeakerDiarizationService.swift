import Foundation
import CoreML
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

    /// Which audio track a set of diarization models is tuned for.
    private enum Track {
        /// Mixed audio fallback: at least two speakers, tighter clustering.
        case mixed
        /// System audio only: remote speakers, no speaker count constraint.
        case remote
        /// Mic audio only: forced to a single speaker ("You").
        case local
    }

    private nonisolated(unsafe) var mixedManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var remoteManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var localManager: OfflineDiarizerManager?

    /// Prepare diarization models with meeting-optimized config for mixed audio fallback.
    public func prepareModels() async throws {
        try await prepareManager(for: .mixed)
    }

    /// Run speaker diarization on mixed audio (fallback path).
    public func diarize(url: URL) async throws -> [SpeakerSegment] {
        logger.notice("[Voom] Starting mixed speaker diarization: \(url.lastPathComponent)")
        return mapSegments(try await process(.mixed, url: url))
    }

    /// Diarize system-only audio to identify remote speakers.
    /// Returns segments labeled "Speaker 1", "Speaker 2", etc.
    public func diarizeRemoteSpeakers(systemAudioURL: URL) async throws -> [SpeakerSegment] {
        logger.notice("[Voom] Diarizing remote speakers: \(systemAudioURL.lastPathComponent)")
        return mapSegments(try await process(.remote, url: systemAudioURL))
    }

    /// Diarize mic-only audio to identify when the local user is speaking.
    /// Returns time segments for "You".
    public func diarizeLocalSpeaker(micAudioURL: URL) async throws -> [SpeakerSegment] {
        logger.notice("[Voom] Diarizing local speaker: \(micAudioURL.lastPathComponent)")
        let result = try await process(.local, url: micAudioURL)

        // All segments from mic are "You"
        return result.segments.map { segment in
            SpeakerSegment(
                speaker: "You",
                startTime: TimeInterval(segment.startTimeSeconds),
                endTime: TimeInterval(segment.endTimeSeconds)
            )
        }
    }

    // MARK: - Model Lifecycle

    /// Diarize `url`, and if models that were already resident fail, reload them and
    /// try once more. CoreML can invalidate long-resident models — macOS purges the
    /// compiled ANE bundle cache out from under the process — after which every
    /// prediction fails instantly until the models are rebuilt.
    private func process(_ track: Track, url: URL) async throws -> DiarizationResult {
        let hadResidentModels = hasResidentManager(for: track)
        do {
            return try await runDiarization(track, url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard hadResidentModels, error.isCoreMLFailure else { throw error }
            logger.error("[Voom] Diarization failed on resident models (\(error.localizedDescription)); reloading models and retrying once")
            // Released rather than cleaned up: a diarization already in flight keeps
            // its own reference to the old manager and finishes on it.
            discardManager(for: track)
            return try await runDiarization(track, url: url)
        }
    }

    private func runDiarization(_ track: Track, url: URL) async throws -> DiarizationResult {
        try await prepareManager(for: track)
        switch track {
        case .mixed:
            guard let mixedManager else { throw DiarizationSetupError.managerUnavailable }
            return try await mixedManager.process(url)
        case .remote:
            guard let remoteManager else { throw DiarizationSetupError.managerUnavailable }
            return try await remoteManager.process(url)
        case .local:
            guard let localManager else { throw DiarizationSetupError.managerUnavailable }
            return try await localManager.process(url)
        }
    }

    private func hasResidentManager(for track: Track) -> Bool {
        switch track {
        case .mixed: mixedManager != nil
        case .remote: remoteManager != nil
        case .local: localManager != nil
        }
    }

    private func discardManager(for track: Track) {
        switch track {
        case .mixed: mixedManager = nil
        case .remote: remoteManager = nil
        case .local: localManager = nil
        }
    }

    private func prepareManager(for track: Track) async throws {
        guard !hasResidentManager(for: track) else { return }

        let config: OfflineDiarizerConfig
        switch track {
        case .mixed: config = OfflineDiarizerConfig(clusteringThreshold: 0.45).withSpeakers(min: 2)
        case .remote: config = OfflineDiarizerConfig(clusteringThreshold: 0.6)
        case .local: config = OfflineDiarizerConfig(clusteringThreshold: 0.6).withSpeakers(min: 1, max: 1)
        }

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()

        switch track {
        case .mixed:
            mixedManager = manager
            logger.notice("[Voom] Speaker diarization models ready (mixed, threshold=0.45, minSpeakers=2)")
        case .remote:
            remoteManager = manager
            logger.notice("[Voom] Remote speaker diarization models ready (threshold=0.6)")
        case .local:
            localManager = manager
            logger.notice("[Voom] Local speaker diarization models ready (numSpeakers=1)")
        }
    }

    private enum DiarizationSetupError: Error {
        case managerUnavailable
    }

    // MARK: - Segment Mapping

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

private extension Error {
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
