import Foundation
import CoreML
import os
import FluidAudio
import VoomCore

private let logger = Logger(subsystem: "com.voom.app", category: "SpeakerDiarization")

/// Speaker diarization for meetings.
///
/// Remote and mixed audio go through NVIDIA's Nemotron 3 Diarization (end-to-end, up to
/// eight speakers, overlap-aware), falling back to FluidAudio's pyannote clustering
/// pipeline if it can't run. The mic track stays on the clustering pipeline, forced to a
/// single speaker — there it only has to find when the user talks.
public actor SpeakerDiarizationService {
    public static let shared = SpeakerDiarizationService()
    private init() {}

    /// 10.24 s of audio per model call: the most accurate of FluidAudio's streaming presets.
    /// Meetings are diarized after recording, so its ~10 s latency is free.
    private static let nemotronConfig = Nemotron3Config.fast128

    /// CPU + GPU, not the Neural Engine: on some Macs the ANE compile fails and CoreML then
    /// rejects FluidAudio 0.17.1's preallocated output buffers on every prediction
    /// (FluidAudio #951, fix pending in #952). The GPU still runs ~500x real time and
    /// leaves the ANE to the ASR model transcribing alongside.
    private static let nemotronComputeUnits = MLComputeUnits.cpuAndGPU

    private var nemotron: Nemotron3Diarizer?

    /// Which audio track a set of clustering-diarizer models is tuned for.
    private enum Track {
        /// Mixed audio fallback: at least two speakers.
        case mixed
        /// System audio only: remote speakers, no speaker count constraint.
        case remote
        /// Mic audio only: forced to a single speaker ("You").
        case local
    }

    private nonisolated(unsafe) var mixedManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var remoteManager: OfflineDiarizerManager?
    private nonisolated(unsafe) var localManager: OfflineDiarizerManager?

    /// Prepare the primary (Nemotron 3) diarization models.
    public func prepareModels() async throws {
        try await prepareNemotron()
    }

    /// Run speaker diarization on mixed audio (fallback path).
    public func diarize(url: URL) async throws -> [SpeakerSegment] {
        logger.notice("[Voom] Starting mixed speaker diarization: \(url.lastPathComponent)")
        return try await diarizeSpeakers(url: url, fallback: .mixed)
    }

    /// Diarize system-only audio to identify remote speakers.
    /// Returns segments labeled "Speaker 1", "Speaker 2", etc.
    public func diarizeRemoteSpeakers(systemAudioURL: URL) async throws -> [SpeakerSegment] {
        logger.notice("[Voom] Diarizing remote speakers: \(systemAudioURL.lastPathComponent)")
        return try await diarizeSpeakers(url: systemAudioURL, fallback: .remote)
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

    // MARK: - Nemotron 3

    /// Diarize with Nemotron 3. If it can't run (model download failed, CoreML error),
    /// fall back to the clustering pipeline so the meeting still gets speaker labels.
    private func diarizeSpeakers(url: URL, fallback track: Track) async throws -> [SpeakerSegment] {
        do {
            return try await nemotronSegments(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.error("[Voom] Nemotron diarization failed (\(error.localizedDescription)); falling back to clustering diarizer")
            let result = try await process(track, url: url)
            return mapSegments(result.segments.map { ($0.speakerId, TimeInterval($0.startTimeSeconds), TimeInterval($0.endTimeSeconds)) })
        }
    }

    /// Run Nemotron 3, reloading resident models once if CoreML has invalidated them.
    private func nemotronSegments(url: URL) async throws -> [SpeakerSegment] {
        let hadResidentModels = nemotron != nil
        do {
            return try await runNemotron(url: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            guard hadResidentModels, error.isCoreMLFailure else { throw error }
            logger.error("[Voom] Nemotron diarization failed on resident models (\(error.localizedDescription)); reloading models and retrying once")
            nemotron = nil
            return try await runNemotron(url: url)
        }
    }

    private func runNemotron(url: URL) async throws -> [SpeakerSegment] {
        try await prepareNemotron()
        guard let nemotron else { throw DiarizationSetupError.managerUnavailable }

        // Streamed through the diarizer chunk by chunk: an hour-long track is never held
        // in memory whole, only its [frames x 8] speaker probabilities.
        nemotron.reset()
        var probabilities: [Float] = []
        try AudioChunkReader.read(url) { samples in
            try Task.checkCancellation()
            nemotron.appendAudio(samples)
            for chunk in try nemotron.processBufferedAudio() {
                probabilities.append(contentsOf: chunk.probabilities)
            }
        }
        for chunk in try nemotron.finishStream() {
            probabilities.append(contentsOf: chunk.probabilities)
        }

        let speakers = Self.nemotronConfig.numSpeakers
        let segments = Nemotron3Diarizer.segments(
            probabilities: probabilities, frameCount: probabilities.count / speakers, numSpeakers: speakers
        )
        return mapSegments(segments.map { ("\($0.speakerIndex)", TimeInterval($0.startSeconds), TimeInterval($0.endSeconds)) })
    }

    private func prepareNemotron() async throws {
        guard nemotron == nil else { return }
        let models = try await Nemotron3Models.loadFromHuggingFace(
            config: Self.nemotronConfig, computeUnits: Self.nemotronComputeUnits
        )
        nemotron = Nemotron3Diarizer(config: Self.nemotronConfig, models: models)
        logger.notice("[Voom] Nemotron 3 diarization models ready (fast128, up to \(Self.nemotronConfig.numSpeakers) speakers)")
    }

    // MARK: - Clustering Model Lifecycle

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

        // The default threshold is pyannote community-1's tuned AHC cut distance (FluidAudio
        // >= 0.15.6 applies it with pyannote's semantics; larger merges more).
        let config: OfflineDiarizerConfig
        switch track {
        case .mixed: config = OfflineDiarizerConfig().withSpeakers(min: 2)
        case .remote: config = OfflineDiarizerConfig()
        case .local: config = OfflineDiarizerConfig().withSpeakers(min: 1, max: 1)
        }

        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()

        switch track {
        case .mixed:
            mixedManager = manager
            logger.notice("[Voom] Speaker diarization models ready (mixed, minSpeakers=2)")
        case .remote:
            remoteManager = manager
            logger.notice("[Voom] Remote speaker diarization models ready")
        case .local:
            localManager = manager
            logger.notice("[Voom] Local speaker diarization models ready (numSpeakers=1)")
        }
    }

    private enum DiarizationSetupError: Error {
        case managerUnavailable
    }

    // MARK: - Segment Mapping

    /// Label raw diarizer speaker ids "Speaker 1", "Speaker 2", … in order of first appearance.
    private func mapSegments(_ raw: [(speakerId: String, start: TimeInterval, end: TimeInterval)]) -> [SpeakerSegment] {
        var speakerMap: [String: String] = [:]
        var segments: [SpeakerSegment] = []

        for segment in raw.sorted(by: { $0.start < $1.start }) {
            if speakerMap[segment.speakerId] == nil {
                speakerMap[segment.speakerId] = "Speaker \(speakerMap.count + 1)"
            }
            segments.append(SpeakerSegment(
                speaker: speakerMap[segment.speakerId]!,
                startTime: segment.start,
                endTime: segment.end
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
