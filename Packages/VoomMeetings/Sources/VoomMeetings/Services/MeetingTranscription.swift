import Foundation
import os
import VoomCore

private let logger = Logger(subsystem: "com.voom.app", category: "MeetingTranscription")

/// Meeting transcription with split-track speaker diarization.
/// Runs ASR on mixed audio, diarizes system audio for remote speakers,
/// diarizes mic audio for "You" identification, then merges by temporal overlap.
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

        let transcriptSegments = await transcriptTask
        let remoteSpeakers = await remoteTask
        let localSpeakers = await localTask

        if transcriptSegments.isEmpty {
            logger.notice("[Voom] No transcript segments produced")
            return []
        }

        logger.notice("[Voom] Merging: \(transcriptSegments.count) transcript, \(remoteSpeakers.count) remote, \(localSpeakers.count) local segments")

        // Merge with "You" priority
        let labeled = mergeSplitTrackResults(transcriptSegments, remoteSpeakers: remoteSpeakers, localSpeakers: localSpeakers)
        logger.notice("[Voom] Meeting transcription complete: \(labeled.count) labeled segments")
        return labeled
    }

    // MARK: - Mixed Audio Fallback

    private func transcribeWithMixedAudio(fileURL: URL) async -> [TranscriptEntry] {
        async let transcriptTask = transcribe(fileURL: fileURL)
        async let diarizationTask = diarize(fileURL: fileURL)

        let transcriptSegments = await transcriptTask
        let speakerSegments = await diarizationTask

        if transcriptSegments.isEmpty {
            logger.notice("[Voom] No transcript segments produced")
            return []
        }

        if speakerSegments.isEmpty {
            logger.notice("[Voom] Diarization unavailable, returning unlabeled transcript (\(transcriptSegments.count) segments)")
            return transcriptSegments.map { seg in
                TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
            }
        }

        let labeled = mergeTranscriptWithSpeakers(transcriptSegments, speakerSegments)
        logger.notice("[Voom] Meeting transcription complete: \(labeled.count) labeled segments")
        return labeled
    }

    // MARK: - Private Helpers

    private func transcribe(fileURL: URL) async -> [VoomTranscriptSegment] {
        do {
            return try await TranscriptionService.shared.transcribe(audioURL: fileURL)
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

    // MARK: - Split-Track Merge

    /// For each ASR segment, check overlap with "You" segments first.
    /// If >50% overlap → "You". Otherwise find best remote speaker match.
    private func mergeSplitTrackResults(
        _ transcript: [VoomTranscriptSegment],
        remoteSpeakers: [SpeakerSegment],
        localSpeakers: [SpeakerSegment]
    ) -> [TranscriptEntry] {
        transcript.map { seg in
            let segDuration = seg.endTime - seg.startTime
            guard segDuration > 0 else {
                return TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
            }

            // Check "You" overlap first
            let youOverlap = totalOverlap(for: seg, in: localSpeakers)
            if youOverlap / segDuration > 0.5 {
                return TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text, speaker: "You")
            }

            // Find best remote speaker
            let remoteSpeaker = bestMatchingSpeaker(for: seg, in: remoteSpeakers)
            return TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text, speaker: remoteSpeaker)
        }
    }

    /// Total overlap of a transcript segment with a set of speaker segments.
    private func totalOverlap(for segment: VoomTranscriptSegment, in speakers: [SpeakerSegment]) -> TimeInterval {
        var total: TimeInterval = 0
        for speaker in speakers {
            let overlapStart = max(segment.startTime, speaker.startTime)
            let overlapEnd = min(segment.endTime, speaker.endTime)
            if overlapEnd > overlapStart {
                total += overlapEnd - overlapStart
            }
        }
        return total
    }

    // MARK: - Mixed Audio Merge (Fallback)

    private func mergeTranscriptWithSpeakers(
        _ transcript: [VoomTranscriptSegment],
        _ speakers: [SpeakerSegment]
    ) -> [TranscriptEntry] {
        transcript.map { seg in
            let speaker = bestMatchingSpeaker(for: seg, in: speakers)
            return TranscriptEntry(
                startTime: seg.startTime,
                endTime: seg.endTime,
                text: seg.text,
                speaker: speaker
            )
        }
    }

    private func bestMatchingSpeaker(
        for segment: VoomTranscriptSegment,
        in speakers: [SpeakerSegment]
    ) -> String? {
        var bestSpeaker: String?
        var bestOverlap: TimeInterval = 0

        for speaker in speakers {
            let overlapStart = max(segment.startTime, speaker.startTime)
            let overlapEnd = min(segment.endTime, speaker.endTime)
            let overlap = overlapEnd - overlapStart

            if overlap > bestOverlap {
                bestOverlap = overlap
                bestSpeaker = speaker.speaker
            }
        }

        return bestSpeaker
    }
}
