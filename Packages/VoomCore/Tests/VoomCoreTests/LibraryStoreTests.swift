import Testing
import Foundation
@testable import VoomCore

/// End-to-end tests for the SQLite library store: persistence round-trips,
/// the one-time JSON migration, corrupt-index recovery via disk scan, and
/// the quit-path flush.
@MainActor
struct LibraryStoreTests {

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("voom-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeRecording(title: String) -> Recording {
        Recording(
            title: title,
            fileURL: URL(fileURLWithPath: "/tmp/\(title).mp4"),
            duration: 5,
            fileSize: 100,
            width: 100,
            height: 100
        )
    }

    @Test func addUpdateDeleteRoundTripsThroughSQLite() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        var recording = makeRecording(title: "First")
        store.add(recording)

        recording.title = "Renamed"
        recording.summary = "Some summary"
        store.update(recording)
        await store.flush()

        // A second store instance must read the same state back from disk.
        let reread = RecordingStore(directory: dir)
        #expect(reread.recordings.count == 1)
        #expect(reread.recordings.first?.title == "Renamed")
        #expect(reread.recordings.first?.summary == "Some summary")

        reread.delete(reread.recordings[0])
        await reread.flush()
        let afterDelete = RecordingStore(directory: dir)
        #expect(afterDelete.recordings.isEmpty)
    }

    @Test func foldersAndTagsPersist() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        store.addFolder(Folder(name: "Work"))
        store.addTag(RecordingTag(name: "demo", colorHex: "#ffffff"))
        await store.flush()

        let reread = RecordingStore(directory: dir)
        #expect(reread.folders.map(\.name) == ["Work"])
        #expect(reread.availableTags.map(\.name) == ["demo"])
    }

    @Test func migratesLegacyJSONIntoSQLiteAndRenamesIt() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let legacy = [makeRecording(title: "Legacy A"), makeRecording(title: "Legacy B")]
        let data = try JSONEncoder().encode(legacy)
        try data.write(to: dir.appendingPathComponent(".recordings.json"))

        let store = RecordingStore(directory: dir)
        await store.flush()
        #expect(store.recordings.count == 2)
        #expect(Set(store.recordings.map(\.title)) == ["Legacy A", "Legacy B"])

        // Original file renamed, not deleted; not re-imported on relaunch.
        #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recordings.json").path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".recordings.json.migrated").path))

        let reread = RecordingStore(directory: dir)
        #expect(reread.recordings.count == 2)
    }

    @Test func corruptLegacyJSONIsPreservedAndVideosRecoveredByDiskScan() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data("{definitely not json".utf8).write(to: dir.appendingPathComponent(".recordings.json"))
        // Two orphaned videos on disk that the index knows nothing about.
        try Data([0x00, 0x01]).write(to: dir.appendingPathComponent("Voom-2025-01-01-000000.mp4"))
        try Data([0x00, 0x01]).write(to: dir.appendingPathComponent("Voom-2025-01-02-000000.mp4"))

        let store = RecordingStore(directory: dir)
        await store.flush()

        // The corrupt file is preserved for forensics…
        let contents = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(contents.contains { $0.hasPrefix(".recordings.json.corrupt-") })
        // …and the MP4s are visible again instead of silently lost.
        #expect(store.recordings.count == 2)
    }

    @Test func oneCorruptRowDoesNotTakeDownTheLibrary() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = RecordingStore(directory: dir)
        store.add(makeRecording(title: "Good"))
        await store.flush()

        // Corrupt one row's JSON directly in SQLite.
        let db = try LibraryDatabase(directory: dir)
        _ = db // open/close to make sure the file exists
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [
            dir.appendingPathComponent(LibraryDatabase.fileName).path,
            "INSERT INTO recordings (id, created_at, json) VALUES ('broken', 0, '{not json');",
        ]
        try process.run()
        process.waitUntilExit()

        let reread = RecordingStore(directory: dir)
        #expect(reread.recordings.map(\.title) == ["Good"]) // bad row skipped, good row kept
    }
}
