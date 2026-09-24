import Foundation
import os
import VoomCore

private let logger = Logger(subsystem: "com.voom.app", category: "MeetingTranscription")

/// Meeting transcription with split-track speaker diarization.
/// Runs ASR on mixed audio, diarizes system audio for remote speakers,
/// diarizes mic audio for "You" identification, then labels every word
/// and re-segments the transcript wherever the speaker changes.
public actor MeetingTranscription {
    public static let shared = MeetingTranscription()
    private init() {}

    /// Transcribe a meeting recording with split-track speaker diarization.
    /// - Parameters:
    ///   - fileURL: Mixed audio/video file for ASR transcription
    ///   - micReferenceURL: Mic-only audio for "You" identification (nil if mic disabled)
    ///   - systemReferenceURL: System-only audio for remote speaker separation (nil for fallback)
    public func transcribeMeeting(
        fileURL: URL,
        micReferenceURL: URL? = nil,
        systemReferenceURL: URL? = nil
    ) async -> [TranscriptEntry] {
        logger.notice("[Voom] Starting meeting transcription: \(fileURL.lastPathComponent)")

        // If we have split tracks, use the improved pipeline
        if let systemRef = systemReferenceURL {
            return await transcribeWithSplitTracks(
                fileURL: fileURL,
                micReferenceURL: micReferenceURL,
                systemReferenceURL: systemRef
            )
        }

        // Fallback: mixed audio diarization (legacy path)
        return await transcribeWithMixedAudio(fileURL: fileURL)
    }

    // MARK: - Split-Track Pipeline

    private func transcribeWithSplitTracks(
        fileURL: URL,
        micReferenceURL: URL?,
        systemReferenceURL: URL
    ) async -> [TranscriptEntry] {
        // Run all tasks in parallel
        async let transcriptTask = transcribe(fileURL: fileURL)
        async let remoteTask = diarizeRemote(systemAudioURL: systemReferenceURL)
        async let localTask = diarizeLocal(micAudioURL: micReferenceURL)
        async let echoTask = loadEchoDetector(micAudioURL: micReferenceURL, systemAudioURL: systemReferenceURL)

        let tokens = await transcriptTask
        let remoteSpeakers = await remoteTask
        let localSpeakers = await localTask
        let echo = await echoTask

        if tokens.isEmpty {
            logger.notice("[Voom] No transcript segments produced")
            return []
        }

        // Per word: mic speech makes it "You" — unless it's remote audio leaking from the
        // speakers into the mic — otherwise the remote speaker talking most over it.
        let words = TranscriptSegmenter.words(from: tokens)
        var echoWords = 0
        let labels: [String?] = words.map { word in
            if SpeakerAttribution.coverage(of: word, by: localSpeakers) > 0.5 {
                guard echo?.isEcho(start: word.startTime, end: word.endTime) == true else { return "You" }
                echoWords += 1
            }
            if let remote = SpeakerAttribution.dominantSpeaker(for: word, in: remoteSpeakers) { return remote }
            // The recording is system audio plus the mic: with the system silent, the word
            // can only have come through the mic, even if the mic VAD missed it.
            if echo?.systemIsSilent(start: word.startTime, end: word.endTime) == true { return "You" }
            return nil
        }

        logger.notice("[Voom] Merging: \(words.count) words, \(remoteSpeakers.count) remote, \(localSpeakers.count) local segments, \(echoWords) mic words rejected as speaker echo")
        let labeled = entries(from: tokens, words: words, labels: labels)
        logger.notice("[Voom] Meeting transcription complete: \(labeled.count) labeled segments")
        return labeled
    }

    // MARK: - Mixed Audio Fallback

    private func transcribeWithMixedAudio(fileURL: URL) async -> [TranscriptEntry] {
        async let transcriptTask = transcribe(fileURL: fileURL)
        async let diarizationTask = diarize(fileURL: fileURL)

        let tokens = await transcriptTask
        let speakerSegments = await diarizationTask

        if tokens.isEmpty {
            logger.notice("[Voom] No transcript segments produced")
            return []
        }

        if speakerSegments.isEmpty {
            let segments = TranscriptSegmenter.segments(from: tokens)
            logger.notice("[Voom] Diarization unavailable, returning unlabeled transcript (\(segments.count) segments)")
            return segments.map { TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime, text: $0.text) }
        }

        let words = TranscriptSegmenter.words(from: tokens)
        let labels = words.map { SpeakerAttribution.dominantSpeaker(for: $0, in: speakerSegments) }
        let labeled = entries(from: tokens, words: words, labels: labels)
        logger.notice("[Voom] Meeting transcription complete: \(labeled.count) labeled segments")
        return labeled
    }

    // MARK: - Private Helpers

    /// Smooth the per-word labels and cut the transcript into single-speaker segments.
    private func entries(from tokens: [VoomTranscriptToken], words: [VoomTranscriptWord], labels: [String?]) -> [TranscriptEntry] {
        let speakers = SpeakerAttribution.resolve(labels, words: words)
        return TranscriptSegmenter.segments(from: tokens, wordSpeakers: speakers).map {
            TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime, text: $0.text, speaker: $0.speaker)
        }
    }

    private func transcribe(fileURL: URL) async -> [VoomTranscriptToken] {
        do {
            return try await TranscriptionService.shared.transcribeTokens(audioURL: fileURL)
        } catch {
            logger.error("[Voom] Transcription failed: \(error)")
            return []
        }
    }

    private func diarize(fileURL: URL) async -> [SpeakerSegment] {
        do {
            return try await SpeakerDiarizationService.shared.diarize(url: fileURL)
        } catch {
            logger.error("[Voom] Diarization failed: \(error)")
            return []
        }
    }

    private func diarizeRemote(systemAudioURL: URL) async -> [SpeakerSegment] {
        do {
            return try await SpeakerDiarizationService.shared.diarizeRemoteSpeakers(systemAudioURL: systemAudioURL)
        } catch {
            logger.error("[Voom] Remote diarization failed: \(error)")
            return []
        }
    }

    private func diarizeLocal(micAudioURL: URL?) async -> [SpeakerSegment] {
        guard let micURL = micAudioURL else { return [] }
        do {
            return try await SpeakerDiarizationService.shared.diarizeLocalSpeaker(micAudioURL: micURL)
        } catch {
            logger.error("[Voom] Local diarization failed: \(error)")
            return []
        }
    }

    /// Nonisolated so decoding both tracks runs alongside ASR and diarization.
    private nonisolated func loadEchoDetector(micAudioURL: URL?, systemAudioURL: URL) async -> EchoBleedDetector? {
        guard let micURL = micAudioURL else { return nil }
        do {
            return try EchoBleedDetector.load(micURL: micURL, systemURL: systemAudioURL)
        } catch {
            // Without it, mic speech is taken at face value, as before.
            logger.error("[Voom] Echo detection unavailable: \(error)")
            return nil
        }
    }
}
