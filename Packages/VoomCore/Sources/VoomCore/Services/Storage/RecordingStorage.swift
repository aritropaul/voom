import Foundation
@preconcurrency import AVFoundation
import AppKit
import CoreImage
import os

private let logger = Logger(subsystem: "com.voom.app", category: "Storage")

@Observable @MainActor
public final class RecordingStore {
    public static let shared = RecordingStore()

    public var recordings: [Recording] = []
    public var folders: [Folder] = []
    public var availableTags: [RecordingTag] = []

    private let saveQueue = DispatchQueue(label: "voom.store.save")

    private let storageURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(".recordings.json")
    }()

    private let foldersURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        return dir.appendingPathComponent(".folders.json")
    }()

    private let tagsURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        return dir.appendingPathComponent(".tags.json")
    }()

    public init() {
        load()
        loadFolders()
        loadTags()
    }

    public func load() {
        guard let data = try? Data(contentsOf: storageURL) else { return }
        do {
            recordings = try JSONDecoder().decode([Recording].self, from: data)
        } catch {
            logger.error("[Voom] Failed to decode recordings: \(error)")
            // Don't overwrite — keep recordings empty but don't save
        }
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        let url = storageURL
        saveQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        save()
    }

    public func update(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
            save()
        }
    }

    public func delete(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        if let thumbURL = recording.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        recordings.removeAll { $0.id == recording.id }
        save()
    }

    public func recording(for id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    // MARK: - Folders

    public func loadFolders() {
        guard let data = try? Data(contentsOf: foldersURL) else { return }
        folders = (try? JSONDecoder().decode([Folder].self, from: data)) ?? []
    }

    public func saveFolders() {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: foldersURL, options: .atomic)
    }

    public func addFolder(_ folder: Folder) {
        folders.append(folder)
        saveFolders()
    }

    public func updateFolder(_ folder: Folder) {
        if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[idx] = folder
            saveFolders()
        }
    }

    public func deleteFolder(_ folder: Folder) {
        // Remove folder assignment from recordings
        for i in recordings.indices where recordings[i].folderID == folder.id {
            recordings[i].folderID = nil
        }
        folders.removeAll { $0.id == folder.id }
        saveFolders()
        save()
    }

    public func recordings(in folder: Folder) -> [Recording] {
        recordings.filter { $0.folderID == folder.id }
    }

    // MARK: - Tags

    public func loadTags() {
        guard let data = try? Data(contentsOf: tagsURL) else { return }
        availableTags = (try? JSONDecoder().decode([RecordingTag].self, from: data)) ?? []
    }

    public func saveTags() {
        guard let data = try? JSONEncoder().encode(availableTags) else { return }
        try? data.write(to: tagsURL, options: .atomic)
    }

    public func addTag(_ tag: RecordingTag) {
        availableTags.append(tag)
        saveTags()
    }

    public func deleteTag(_ tag: RecordingTag) {
        // Remove tag from recordings
        for i in recordings.indices {
            recordings[i].tags?.removeAll { $0.id == tag.id }
        }
        availableTags.removeAll { $0.id == tag.id }
        saveTags()
        save()
    }

    public func backfillTitlesAndSummaries() {
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
            logger.notice("[Voom] Backfilled titles/summaries for \(candidates.count) recordings")
        }
    }

    // MARK: - Auto-Transcription

    public func autoTranscribe(recordingID: UUID, fileURL: URL) {
        let capturedID = recordingID
        let capturedURL = fileURL
        Task.detached {
            await MainActor.run {
                if var rec = RecordingStore.shared.recording(for: capturedID) {
                    rec.isTranscribing = true
                    RecordingStore.shared.update(rec)
                }
            }
            do {
                logger.notice("[Voom] Auto-transcription starting for \(capturedURL.lastPathComponent)")
                let segments = try await TranscriptionService.shared.transcribe(audioURL: capturedURL)
                logger.notice("[Voom] Auto-transcription got \(segments.count) segments")
                let entries = segments.map {
                    TranscriptEntry(startTime: $0.startTime, endTime: $0.endTime, text: $0.text)
                }
                let generatedTitle = await TextAnalysisService.shared.generateTitle(from: entries)
                let generatedSummary = await TextAnalysisService.shared.generateSummary(from: entries)
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.transcriptSegments = entries
                        if !generatedTitle.isEmpty { rec.title = generatedTitle }
                        rec.summary = generatedSummary.isEmpty ? nil : generatedSummary
                        rec.isTranscribed = !segments.isEmpty
                        rec.isTranscribing = false
                        RecordingStore.shared.update(rec)
                    }
                }
            } catch {
                logger.error("[Voom] Auto-transcription failed: \(error)")
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.isTranscribing = false
                        RecordingStore.shared.update(rec)
                    }
                }
            }
        }
    }
}

public actor RecordingStorage {
    public static let shared = RecordingStorage()

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

    private static let recordingDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f
    }()

    public init() {}

    public func newRecordingURL() -> URL {
        let filename = "Voom-\(Self.recordingDateFormatter.string(from: Date())).mp4"
        return baseDirectory.appendingPathComponent(filename)
    }

    public func thumbnailURL(for recordingID: UUID) -> URL {
        thumbnailDirectory.appendingPathComponent("\(recordingID.uuidString).jpg")
    }

    public func generateThumbnail(for videoURL: URL, recordingID: UUID) async -> URL? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1080)

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
            logger.error("[Voom] Thumbnail generation failed: \(error)")
        }
        return nil
    }

    public func fileSize(at url: URL) -> Int64 {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as? Int64) ?? 0
    }

    public func videoDuration(at url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        do {
            let duration = try await asset.load(.duration)
            return duration.seconds
        } catch {
            return 0
        }
    }

    public func editedRecordingURL(for originalURL: URL, suffix: String) -> URL {
        let name = originalURL.deletingPathExtension().lastPathComponent
        let ext = originalURL.pathExtension
        return baseDirectory.appendingPathComponent("\(name)-\(suffix).\(ext)")
    }

    public func videoResolution(at url: URL) async -> (width: Int, height: Int) {
        let asset = AVURLAsset(url: url)
        do {
            let tracks = try await asset.loadTracks(withMediaType: .video)
            if let track = tracks.first {
                let size = try await track.load(.naturalSize)
                return (Int(size.width), Int(size.height))
            }
        } catch {
            logger.error("[Voom] Failed to get video resolution: \(error)")
        }
        return (0, 0)
    }
}
