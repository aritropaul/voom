import Testing
@testable import VoomCore

struct FillerWordDetectorTests {

    private func entry(_ text: String, start: Double = 0, end: Double = 10) -> TranscriptEntry {
        TranscriptEntry(startTime: start, endTime: end, text: text)
    }

    @Test func detectsSingleWordFillers() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("So um this is uh a demo")
        ])
        let words = detections.map(\.word)
        #expect(words.contains("um"))
        #expect(words.contains("uh"))
        #expect(words.contains("so"))
    }

    @Test func ignoresCleanSpeech() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("This sentence contains no fillers at all")
        ])
        #expect(detections.isEmpty)
    }

    @Test func detectsMultiWordFillers() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("and you know it just works")
        ])
        #expect(detections.map(\.word).contains("you know"))
    }

    @Test func detectsIMeanDespiteLowercasing() async {
        // Regression: the filler list previously held "I mean" (capital I)
        // which could never match the lowercased text.
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("I mean it works")
        ])
        #expect(detections.map(\.word).contains("i mean"))
    }

    @Test func stripsPunctuationBeforeMatching() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("Um, that works.")
        ])
        #expect(detections.map(\.word).contains("um"))
    }

    @Test func detectionsAreSortedByTime() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("like one", start: 10, end: 12),
            entry("um two", start: 0, end: 2),
        ])
        #expect(detections.count >= 2)
        let starts = detections.map { $0.estimatedTimeRange.start.seconds }
        #expect(starts == starts.sorted())
    }

    /// KNOWN LIMITATION, documented as a pinned behavior: the multi-word
    /// matcher is substring-based, so "unkind of" false-positives on
    /// "kind of". If this expectation ever fails, the matcher got smarter —
    /// update this test to assert the (now correct) absence instead.
    @Test func substringFalsePositiveIsCurrentBehavior() async {
        let detections = await FillerWordDetector.shared.detect(in: [
            entry("that was unkind of you")
        ])
        #expect(detections.map(\.word).contains("kind of"))
    }
}
