import Foundation
import AVFoundation
import CoreMedia

public actor VideoEditor {
    public static let shared = VideoEditor()

    private init() {}

    public enum VideoEditError: LocalizedError {
        case invalidAsset
        case exportFailed(String)
        case noVideoTrack
        case invalidTimeRange

        public var errorDescription: String? {
            switch self {
            case .invalidAsset: return "Invalid video asset."
            case .exportFailed(let msg): return "Export failed: \(msg)"
            case .noVideoTrack: return "No video track found."
            case .invalidTimeRange: return "Invalid time range."
            }
        }
    }

    // MARK: - Trim

    public func trim(sourceURL: URL, startTime: CMTime, endTime: CMTime, outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)

        let clampedStart = CMTimeClampToRange(startTime, range: CMTimeRange(start: .zero, duration: duration))
        let clampedEnd = CMTimeClampToRange(endTime, range: CMTimeRange(start: .zero, duration: duration))
        let timeRange = CMTimeRange(start: clampedStart, end: clampedEnd)

        guard timeRange.duration.seconds > 0 else { throw VideoEditError.invalidTimeRange }

        guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoEditError.exportFailed("Could not create export session.")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4
        exportSession.timeRange = timeRange

        await exportSession.export()

        if let error = exportSession.error {
            throw VideoEditError.exportFailed(error.localizedDescription)
        }
        guard exportSession.status == .completed else {
            throw VideoEditError.exportFailed("Export status: \(exportSession.status.rawValue)")
        }
    }

    // MARK: - Cut Sections

    public func cutSections(sourceURL: URL, removals: [CMTimeRange], outputURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let duration = try await asset.load(.duration)

        let composition = AVMutableComposition()

        let keepRanges = invertRanges(removals: removals, totalDuration: duration)

        guard !keepRanges.isEmpty else { throw VideoEditError.invalidTimeRange }

        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)

        let compositionVideoTrack = videoTracks.isEmpty ? nil : composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compositionAudioTrack = audioTracks.isEmpty ? nil : composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for range in keepRanges {
            if let videoTrack = videoTracks.first, let compTrack = compositionVideoTrack {
                try compTrack.insertTimeRange(range, of: videoTrack, at: insertTime)
            }
            if let audioTrack = audioTracks.first, let compTrack = compositionAudioTrack {
                try compTrack.insertTimeRange(range, of: audioTrack, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, range.duration)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoEditError.exportFailed("Could not create export session.")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        await exportSession.export()

        if let error = exportSession.error {
            throw VideoEditError.exportFailed(error.localizedDescription)
        }
        guard exportSession.status == .completed else {
            throw VideoEditError.exportFailed("Export status: \(exportSession.status.rawValue)")
        }
    }

    // MARK: - Stitch

    public func stitch(sourceURLs: [URL], outputURL: URL) async throws {
        guard sourceURLs.count >= 2 else { throw VideoEditError.invalidAsset }

        let composition = AVMutableComposition()
        let compositionVideoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let compositionAudioTrack = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var insertTime = CMTime.zero
        for url in sourceURLs {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let timeRange = CMTimeRange(start: .zero, duration: duration)

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)

            if let videoTrack = videoTracks.first, let compTrack = compositionVideoTrack {
                try compTrack.insertTimeRange(timeRange, of: videoTrack, at: insertTime)
            }
            if let audioTrack = audioTracks.first, let compTrack = compositionAudioTrack {
                try compTrack.insertTimeRange(timeRange, of: audioTrack, at: insertTime)
            }
            insertTime = CMTimeAdd(insertTime, duration)
        }

        guard let exportSession = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw VideoEditError.exportFailed("Could not create export session.")
        }
        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        await exportSession.export()

        if let error = exportSession.error {
            throw VideoEditError.exportFailed(error.localizedDescription)
        }
        guard exportSession.status == .completed else {
            throw VideoEditError.exportFailed("Export status: \(exportSession.status.rawValue)")
        }
    }

    // MARK: - Adjust Transcript After Cut

    public func adjustTranscript(segments: [TranscriptEntry], removals: [CMTimeRange]) -> [TranscriptEntry] {
        var adjusted: [TranscriptEntry] = []
        let sortedRemovals = removals.sorted { $0.start < $1.start }

        for var segment in segments {
            let segRange = CMTimeRange(
                start: CMTime(seconds: segment.startTime, preferredTimescale: 600),
                end: CMTime(seconds: segment.endTime, preferredTimescale: 600)
            )

            var fullyRemoved = false
            for removal in sortedRemovals {
                if CMTimeRangeContainsTimeRange(removal, otherRange: segRange) {
                    fullyRemoved = true
                    break
                }
            }
            if fullyRemoved { continue }

            var offset: CMTime = .zero
            for removal in sortedRemovals {
                if removal.end <= segRange.start {
                    offset = CMTimeAdd(offset, removal.duration)
                } else if removal.start < segRange.start {
                    let overlap = CMTimeSubtract(removal.end, segRange.start)
                    offset = CMTimeAdd(offset, CMTimeSubtract(removal.duration, overlap))
                }
            }

            segment.startTime = max(0, CMTimeSubtract(CMTime(seconds: segment.startTime, preferredTimescale: 600), offset).seconds)
            segment.endTime = max(segment.startTime, CMTimeSubtract(CMTime(seconds: segment.endTime, preferredTimescale: 600), offset).seconds)
            adjusted.append(segment)
        }

        return adjusted
    }

    // MARK: - Helpers

    private func invertRanges(removals: [CMTimeRange], totalDuration: CMTime) -> [CMTimeRange] {
        let sorted = removals.sorted { $0.start < $1.start }
        var keepRanges: [CMTimeRange] = []
        var cursor = CMTime.zero

        for removal in sorted {
            if removal.start > cursor {
                keepRanges.append(CMTimeRange(start: cursor, end: removal.start))
            }
            cursor = CMTimeMaximum(cursor, removal.end)
        }

        if cursor < totalDuration {
            keepRanges.append(CMTimeRange(start: cursor, end: totalDuration))
        }

        return keepRanges
    }
}
