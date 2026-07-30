import Testing
import CoreMedia
@testable import VoomCore

/// `adjustTranscript` keeps transcript timestamps in sync with the video
/// after cut sections are removed — the overlap math here is exactly the kind
/// of regression that ships silently without tests.
struct VideoEditorAdjustTranscriptTests {

    private func entry(_ start: Double, _ end: Double, _ text: String = "x") -> TranscriptEntry {
        TranscriptEntry(startTime: start, endTime: end, text: text)
    }

    private func range(_ start: Double, _ end: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            end: CMTime(seconds: end, preferredTimescale: 600)
        )
    }

    @Test func removalBeforeSegmentShiftsItLeft() async {
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(10, 12)],
            removals: [range(0, 4)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 6) < 0.01)
        #expect(abs(result[0].endTime - 8) < 0.01)
    }

    @Test func segmentInsideRemovalIsDropped() async {
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(5, 6), entry(20, 21)],
            removals: [range(4, 8)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 16) < 0.01)
    }

    @Test func removalOverlappingSegmentStartUsesPartialOffset() async {
        // Removal 8-12 straddles a 10-14 segment. The start (inside the
        // removal) clamps to the removal start's new position (8); the end
        // (past the removal) shifts by the FULL removal duration (14-4=10).
        // v4.1.0 shipped end=12 here — the surviving content is original
        // 12-14, which lands at 8-10 in the edited timeline.
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(10, 14)],
            removals: [range(8, 12)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 8) < 0.01)
        #expect(abs(result[0].endTime - 10) < 0.01)
    }

    @Test func removalOverlappingSegmentEndClampsTheEnd() async {
        // Removal 12-16 covers the tail of a 10-14 segment: start is
        // untouched, end clamps to the removal start (12).
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(10, 14)],
            removals: [range(12, 16)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 10) < 0.01)
        #expect(abs(result[0].endTime - 12) < 0.01)
    }

    @Test func multipleRemovalsAccumulate() async {
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(30, 32)],
            removals: [range(0, 5), range(10, 15)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 20) < 0.01)
        #expect(abs(result[0].endTime - 22) < 0.01)
    }

    @Test func removalEndingExactlyAtSegmentStartShiftsFully() async {
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(10, 12)],
            removals: [range(5, 10)]
        )
        #expect(result.count == 1)
        #expect(abs(result[0].startTime - 5) < 0.01)
    }

    @Test func noRemovalsLeavesSegmentsUntouched() async {
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(1, 2), entry(3, 4)],
            removals: []
        )
        #expect(result.count == 2)
        #expect(result[0].startTime == 1)
        #expect(result[1].endTime == 4)
    }

    @Test func timesNeverGoNegative() async {
        // Removal larger than everything before the segment.
        let result = await VideoEditor.shared.adjustTranscript(
            segments: [entry(2, 3)],
            removals: [range(0, 2)]
        )
        #expect(result.count == 1)
        #expect(result[0].startTime >= 0)
        #expect(result[0].endTime >= result[0].startTime)
    }
}
