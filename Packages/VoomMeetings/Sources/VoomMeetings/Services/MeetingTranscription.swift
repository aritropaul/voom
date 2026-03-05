import Foundation
import AVFoundation
import VoomCore

/// Dual-track meeting transcription: transcribes system audio and mic separately,
/// then interleaves with speaker labels ("Speaker" for system audio, "You" for mic).
public actor MeetingTranscription {
    public static let shared = MeetingTranscription()
    private init() {}

    /// Transcribe a meeting recording with speaker differentiation.
    /// Extracts system audio and mic tracks, transcribes each independently,
    /// labels segments, and interleaves by timestamp.
    public func transcribeMeeting(fileURL: URL) async -> [TranscriptEntry] {
        let asset = AVURLAsset(url: fileURL)

        // Get audio tracks
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio) else {
            // Fallback: single-track transcription without speaker labels
            let segments = try? await TranscriptionService.shared.transcribe(audioURL: fileURL)
            return (segments ?? []).map { seg in
                TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
            }
        }

        if tracks.count >= 2 {
            // Dual-track: separate system audio (track 0) and mic (track 1)
            async let systemSegments = transcribeTrack(asset: asset, trackIndex: 0, speaker: "Speaker")
            async let micSegments = transcribeTrack(asset: asset, trackIndex: 1, speaker: "You")

            let system = await systemSegments
            let mic = await micSegments

            // Interleave by timestamp
            return interleaveSegments(system: system, mic: mic)
        } else {
            // Single audio track — transcribe without speaker labels
            let segments = try? await TranscriptionService.shared.transcribe(audioURL: fileURL)
            return (segments ?? []).map { seg in
                TranscriptEntry(startTime: seg.startTime, endTime: seg.endTime, text: seg.text)
            }
        }
    }

    /// Extract a single audio track and transcribe it.
    private func transcribeTrack(asset: AVURLAsset, trackIndex: Int, speaker: String) async -> [TranscriptEntry] {
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio),
              trackIndex < tracks.count else { return [] }

        // Export the specific track to a temporary file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("voom-\(speaker)-\(UUID().uuidString).m4a")

        do {
            let composition = AVMutableComposition()
            guard let compositionTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { return [] }

            let duration = try await asset.load(.duration)
            try compositionTrack.insertTimeRange(
                CMTimeRange(start: .zero, duration: duration),
                of: tracks[trackIndex],
                at: .zero
            )

            // Export to M4A
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetAppleM4A
            ) else { return [] }

            exportSession.outputURL = tempURL
            exportSession.outputFileType = .m4a

            await exportSession.export()
            guard exportSession.status == .completed else { return [] }

            // Transcribe the extracted track
            let segments = try await TranscriptionService.shared.transcribe(audioURL: tempURL)

            // Label with speaker
            let labeled = segments.map { seg -> TranscriptEntry in
                TranscriptEntry(
                    startTime: seg.startTime,
                    endTime: seg.endTime,
                    text: seg.text,
                    speaker: speaker
                )
            }

            // Clean up temp file
            try? FileManager.default.removeItem(at: tempURL)

            return labeled
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return []
        }
    }

    /// Interleave system and mic segments by timestamp.
    private func interleaveSegments(system: [TranscriptEntry], mic: [TranscriptEntry]) -> [TranscriptEntry] {
        var result = system + mic
        result.sort { $0.startTime < $1.startTime }
        return result
    }

    /// After transcription, merge the dual-track MP4 into a single mixed audio track.
    /// This makes the final file playable with both sides audible.
    public func mergeAudioTracks(fileURL: URL) async -> Bool {
        let asset = AVURLAsset(url: fileURL)
        guard let audioTracks = try? await asset.loadTracks(withMediaType: .audio),
              audioTracks.count >= 2 else { return false }

        let tempURL = fileURL.deletingPathExtension()
            .appendingPathExtension("merged")
            .appendingPathExtension("mp4")

        do {
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)

            // Add video track
            if let videoTrack = try? await asset.loadTracks(withMediaType: .video).first,
               let compositionVideoTrack = composition.addMutableTrack(
                withMediaType: .video,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try compositionVideoTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: videoTrack,
                    at: .zero
                )
            }

            // Merge both audio tracks into one
            guard let compositionAudioTrack = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { return false }

            for audioTrack in audioTracks {
                try compositionAudioTrack.insertTimeRange(
                    CMTimeRange(start: .zero, duration: duration),
                    of: audioTrack,
                    at: .zero
                )
            }

            // Export
            guard let exportSession = AVAssetExportSession(
                asset: composition,
                presetName: AVAssetExportPresetHighestQuality
            ) else { return false }

            exportSession.outputURL = tempURL
            exportSession.outputFileType = .mp4

            await exportSession.export()
            guard exportSession.status == .completed else { return false }

            // Replace original with merged
            try FileManager.default.removeItem(at: fileURL)
            try FileManager.default.moveItem(at: tempURL, to: fileURL)

            return true
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            return false
        }
    }
}
