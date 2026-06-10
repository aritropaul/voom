import Testing
import Foundation
@testable import VoomCore

/// Guards the schema-evolution contract: a library written by an old app
/// version must always decode in a new one. If adding a field to `Recording`
/// breaks this test, the field needs to be Optional (or get a default via a
/// custom decoder) — shipping it as-is would wipe users' library indexes.
struct RecordingCodableTests {

    @Test func decodesV1FixtureWithoutNewerFields() throws {
        let url = try #require(Bundle.module.url(forResource: "recordings-v1", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        let recordings = try JSONDecoder().decode([Recording].self, from: data)

        #expect(recordings.count == 1)
        let r = try #require(recordings.first)
        #expect(r.title == "Voom-2025-01-15-093000")
        #expect(r.transcriptSegments.count == 1)
        // Every post-v1 field must default to nil.
        #expect(r.summary == nil)
        #expect(r.shareCode == nil)
        #expect(r.chapters == nil)
        #expect(r.blurRegions == nil)
        #expect(r.tags == nil)
        #expect(r.cursorEventsURL == nil)
    }

    @Test func roundTripsCurrentModel() throws {
        var recording = Recording(
            title: "Round Trip",
            fileURL: URL(fileURLWithPath: "/tmp/test.mp4"),
            duration: 12,
            fileSize: 1234,
            width: 1920,
            height: 1080,
            hasWebcam: true,
            hasSystemAudio: true,
            hasMicAudio: false
        )
        recording.transcriptSegments = [TranscriptEntry(startTime: 0, endTime: 1, text: "hi", speaker: "A")]
        recording.chapters = [Chapter(timestamp: 0, title: "Intro")]
        recording.summary = "A summary"
        recording.shareCode = "abc123defg"

        let data = try JSONEncoder().encode(recording)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)

        #expect(decoded.id == recording.id)
        #expect(decoded.title == "Round Trip")
        #expect(decoded.transcriptSegments == recording.transcriptSegments)
        #expect(decoded.chapters == recording.chapters)
        #expect(decoded.shareCode == "abc123defg")
    }
}
