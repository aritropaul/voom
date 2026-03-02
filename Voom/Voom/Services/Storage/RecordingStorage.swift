import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreImage

@Observable @MainActor
final class RecordingStore {
    static let shared = RecordingStore()

    var recordings: [Recording] = []

    private let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".recordings.json")
    }()

    init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        recordings = (try? JSONDecoder().decode([Recording].self, from: data)) ?? []
    }

    func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }

    func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save()
    }

    func update(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
            save()
        }
    }

    func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        if let thumbURL = recording.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    func recording(for id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    func backfillTitlesAndSummaries() {
        let candidates = recordings.filter { $0.isTranscribed && !$0.transcriptSegments.isEmpty && $0.summary == nil }
        guard !candidates.isEmpty else { return }
        Task.detached {
            for candidate in candidates {
                let segments = candidate.transcriptSegments
                let title = await TextAnalysisService.shared.generateTitle(from: segments)
                let summary = await TextAnalysisService.shared.generateSummary(from: segments)
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: candidate.id) {
                        if !title.isEmpty {
                            rec.title = title
                        }
                        rec.summary = summary.isEmpty ? nil : summary
                        RecordingStore.shared.update(rec)
                    }
                }
            }
            NSLog("[Voom] Backfilled titles/summaries for %d recordings", candidates.count)
        }
    }

}

actor RecordingStorage {
    static let shared = RecordingStorage()

    private let baseDirectory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private let thumbnailDirectory: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
            .appendingPathComponent(".thumbnails")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    func newRecordingURL() -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let filename = "Voom-\(formatter.string(from: Date())).mp4"
        return baseDirectory.appendingPathComponent(filename)
    }

    func thumbnailURL(for recordingID: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent("\(recordingID.uuidString).jpg")
    }

    func generateThumbnail(for videoURL: URL, recordingID: UUID) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)

        let time = CMTime(seconds: 1, preferredTimescale: 600)
        do {
            let (image, _) = try await generator.image(at: time)
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            let thumbURL = thumbnailURL(for: recordingID)

            if let tiffData = nsImage.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiffData),
               let jpegData = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                try jpegData.write(to: thumbURL)
                return thumbURL
            }
        } catch {
            print("Thumbnail generation failed: \(error)")
        }
        return nil
    }

    func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
    }

    func videoDuration(at url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds
        } catch {
            return 0
        }
    }

    func videoResolution(at url: URL) async -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                return (Int(size.width), Int(size.height))
            }
        } catch {
            print("Failed to get video resolution: \(error)")
        }
        return (0, 0)
    }
}
