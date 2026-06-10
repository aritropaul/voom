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

    private let directory: URL
    private var database: LibraryDatabase?

    public init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)

        openDatabase()
        migrateFromJSONIfNeeded()
        load()

        if recordings.isEmpty {
            rebuildFromDiskScanIfNeeded()
        }
    }

    private func openDatabase() {
        do {
            database = try LibraryDatabase(directory: directory)
        } catch {
            // A corrupt database must not brick the library: move it aside and
            // start fresh — the MP4s on disk are the real source of truth and
            // the disk-scan rebuild below recovers them.
            logger.error("[Voom] Library database failed to open: \(error). Recreating.")
            let dbURL = directory.appendingPathComponent(LibraryDatabase.fileName)
            let backup = directory.appendingPathComponent("\(LibraryDatabase.fileName).corrupt-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: dbURL, to: backup)
            database = try? LibraryDatabase(directory: directory)
        }
    }

    /// One-time migration from the legacy `.recordings.json` / `.folders.json`
    /// / `.tags.json` files into SQLite. The JSON files are renamed (never
    /// deleted) so a failed migration can always be retried by hand.
    private func migrateFromJSONIfNeeded() {
        guard let database else { return }
        let legacyRecordings = directory.appendingPathComponent(".recordings.json")
        guard FileManager.default.fileExists(atPath: legacyRecordings.path) else { return }

        let existing = database.loadAll()
        guard existing.recordings.isEmpty else {
            // DB already populated — don't re-import stale JSON over it.
            return
        }

        if let data = try? Data(contentsOf: legacyRecordings) {
            do {
                let migrated = try JSONDecoder().decode([Recording].self, from: data)
                for r in migrated { database.upsertRecording(r) }
                try? FileManager.default.moveItem(
                    at: legacyRecordings,
                    to: directory.appendingPathComponent(".recordings.json.migrated")
                )
                logger.notice("[Voom] Migrated \(migrated.count) recordings from JSON to SQLite")
            } catch {
                // Corrupt legacy file: preserve it for forensics; the disk scan
                // in init recovers the videos themselves.
                logger.error("[Voom] Legacy recordings JSON is corrupt (\(error.localizedDescription)) — preserving as .corrupt")
                try? FileManager.default.moveItem(
                    at: legacyRecordings,
                    to: directory.appendingPathComponent(".recordings.json.corrupt-\(Int(Date().timeIntervalSince1970))")
                )
            }
        }

        let legacyFolders = directory.appendingPathComponent(".folders.json")
        if let data = try? Data(contentsOf: legacyFolders),
           let migrated = try? JSONDecoder().decode([Folder].self, from: data) {
            for f in migrated { database.upsertFolder(f) }
            try? FileManager.default.moveItem(at: legacyFolders, to: directory.appendingPathComponent(".folders.json.migrated"))
        }

        let legacyTags = directory.appendingPathComponent(".tags.json")
        if let data = try? Data(contentsOf: legacyTags),
           let migrated = try? JSONDecoder().decode([RecordingTag].self, from: data) {
            for t in migrated { database.upsertTag(t) }
            try? FileManager.default.moveItem(at: legacyTags, to: directory.appendingPathComponent(".tags.json.migrated"))
        }
    }

    /// Recovery path: the library index is empty but `*.mp4` files exist —
    /// synthesize minimal entries so the user's videos are never invisible.
    /// Duration/resolution/thumbnails are probed in the background.
    private func rebuildFromDiskScanIfNeeded() {
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey]))
            ?? []
        let videos = contents.filter { $0.pathExtension.lowercased() == "mp4" }
        guard !videos.isEmpty else { return }

        logger.notice("[Voom] Library empty but \(videos.count) videos on disk — rebuilding index")
        for url in videos {
            var recording = Recording(
                title: url.deletingPathExtension().lastPathComponent,
                fileURL: url,
                duration: 0,
                fileSize: 0,
                width: 0,
                height: 0,
                hasWebcam: false,
                hasSystemAudio: false,
                hasMicAudio: false
            )
            if let created = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                recording.createdAt = created
            }
            add(recording)
        }

        // Probe real metadata off the main thread, skipping unplayable files.
        let ids = recordings.map(\.id)
        Task.detached(priority: .utility) { [weak self] in
            for id in ids {
                guard let self else { return }
                guard let rec = await self.recording(for: id), rec.duration == 0 else { continue }
                let storage = RecordingStorage.shared
                let duration = await storage.videoDuration(at: rec.fileURL)
                let resolution = await storage.videoResolution(at: rec.fileURL)
                let fileSize = await storage.fileSize(at: rec.fileURL)
                let thumb = await storage.generateThumbnail(for: rec.fileURL, recordingID: id)
                await MainActor.run {
                    if var updated = self.recording(for: id) {
                        updated.duration = duration
                        updated.width = resolution.width
                        updated.height = resolution.height
                        updated.fileSize = fileSize
                        updated.thumbnailURL = thumb
                        self.update(updated)
                    }
                }
            }
        }
    }

    /// Reloads all entities from the database (used by the CLI to pick up
    /// rows written by the app process, and by tests).
    public func load() {
        guard let database else { return }
        let all = database.loadAll()
        recordings = all.recordings
        folders = all.folders
        availableTags = all.tags
    }

    /// Blocks until pending writes are durable. Called from the quit guard.
    public func flush() async {
        await database?.flush()
    }

    public func add(_ recording: Recording) {
        recordings.insert(recording, at: 0)
        database?.upsertRecording(recording)
    }

    public func update(_ recording: Recording) {
        if let index = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[index] = recording
            database?.upsertRecording(recording)
        }
    }

    public func delete(_ recording: Recording) {
        // Remove the public share first (best effort) — a deleted recording
        // must not stay reachable on the share worker until expiry.
        if let shareCode = recording.shareCode {
            Task {
                do {
                    try await ShareService.shared.deleteShare(shareCode: shareCode)
                } catch {
                    logger.error("[Voom] Failed to delete share \(shareCode): \(error.localizedDescription)")
                }
            }
        }

        try? FileManager.default.removeItem(at: recording.fileURL)
        if let thumbURL = recording.thumbnailURL {
            try? FileManager.default.removeItem(at: thumbURL)
        }
        // Sidecars (cursor events, zoom keyframes) go with the video.
        if let cursorURL = recording.cursorEventsURL {
            try? FileManager.default.removeItem(at: cursorURL)
        }
        if let zoomURL = recording.zoomKeyframesURL {
            try? FileManager.default.removeItem(at: zoomURL)
        }

        recordings.removeAll { $0.id == recording.id }
        database?.deleteRecording(id: recording.id)
    }

    public func recording(for id: UUID) -> Recording? {
        recordings.first { $0.id == id }
    }

    // MARK: - Folders

    public func addFolder(_ folder: Folder) {
        folders.append(folder)
        database?.upsertFolder(folder)
    }

    public func updateFolder(_ folder: Folder) {
        if let idx = folders.firstIndex(where: { $0.id == folder.id }) {
            folders[idx] = folder
            database?.upsertFolder(folder)
        }
    }

    public func deleteFolder(_ folder: Folder) {
        // Remove folder assignment from recordings
        for i in recordings.indices where recordings[i].folderID == folder.id {
            recordings[i].folderID = nil
            database?.upsertRecording(recordings[i])
        }
        folders.removeAll { $0.id == folder.id }
        database?.deleteFolder(id: folder.id)
    }

    public func recordings(in folder: Folder) -> [Recording] {
        recordings.filter { $0.folderID == folder.id }
    }

    // MARK: - Tags

    public func addTag(_ tag: RecordingTag) {
        availableTags.append(tag)
        database?.upsertTag(tag)
    }

    public func deleteTag(_ tag: RecordingTag) {
        // Remove tag from recordings
        for i in recordings.indices where recordings[i].tags?.contains(where: { $0.id == tag.id }) == true {
            recordings[i].tags?.removeAll { $0.id == tag.id }
            database?.upsertRecording(recordings[i])
        }
        availableTags.removeAll { $0.id == tag.id }
        database?.deleteTag(id: tag.id)
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
                let chapters = await TextAnalysisService.shared.generateChapters(from: entries)
                await MainActor.run {
                    if var rec = RecordingStore.shared.recording(for: capturedID) {
                        rec.transcriptSegments = entries
                        if !generatedTitle.isEmpty { rec.title = generatedTitle }
                        rec.summary = generatedSummary.isEmpty ? nil : generatedSummary
                        if !chapters.isEmpty { rec.chapters = chapters }
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
                try jpegData.write(to: thumbURL, options: .atomic)
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
