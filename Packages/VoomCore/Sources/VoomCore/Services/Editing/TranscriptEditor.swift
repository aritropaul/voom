import Foundation
import CoreMedia

// MARK: - Word Selection

public struct WordSelection: Sendable, Identifiable {
    public let id: UUID
    public let segmentID: UUID
    public let wordIndex: Int
    public let word: String
    public let estimatedTimeRange: CMTimeRange

    public init(segmentID: UUID, wordIndex: Int, word: String, estimatedTimeRange: CMTimeRange) {
        self.id = UUID()
        self.segmentID = segmentID
        self.wordIndex = wordIndex
        self.word = word
        self.estimatedTimeRange = estimatedTimeRange
    }
}

// MARK: - Transcript Editor

public actor TranscriptEditor {
    public static let shared = TranscriptEditor()
    private init() {}

    // MARK: - Time Estimation

    /// Given a TranscriptEntry segment and a range of word indices, estimate the CMTimeRange.
    /// Uses word-position-fraction: wordFraction = index / totalWords, estimatedStart = segment.startTime + (wordFraction * segmentDuration)
    public func estimateTimeRange(segment: TranscriptEntry, wordRange: Range<Int>) -> CMTimeRange {
        let words = segment.text.split(separator: " ")
        let totalWords = max(words.count, 1)
        let segmentDuration = segment.endTime - segment.startTime

        let startFraction = Double(wordRange.lowerBound) / Double(totalWords)
        let endFraction = Double(wordRange.upperBound) / Double(totalWords)

        let startTime = segment.startTime + (startFraction * segmentDuration)
        let endTime = segment.startTime + (endFraction * segmentDuration)

        return CMTimeRange(
            start: CMTime(seconds: startTime, preferredTimescale: 600),
            duration: CMTime(seconds: endTime - startTime, preferredTimescale: 600)
        )
    }

    // MARK: - Selections to Removals

    /// Convert word selections into merged, sorted CMTimeRange removals.
    public func selectionsToRemovals(_ selections: [WordSelection]) -> [CMTimeRange] {
        guard !selections.isEmpty else { return [] }

        let sorted = selections.sorted {
            CMTimeCompare($0.estimatedTimeRange.start, $1.estimatedTimeRange.start) < 0
        }

        var merged: [CMTimeRange] = []
        var current = sorted[0].estimatedTimeRange

        for selection in sorted.dropFirst() {
            let range = selection.estimatedTimeRange
            if CMTimeCompare(range.start, CMTimeRangeGetEnd(current)) <= 0 {
                // Overlapping or adjacent — extend current range
                let end1 = CMTimeRangeGetEnd(current)
                let end2 = CMTimeRangeGetEnd(range)
                let maxEnd = CMTimeCompare(end1, end2) >= 0 ? end1 : end2
                current = CMTimeRange(start: current.start, end: maxEnd)
            } else {
                merged.append(current)
                current = range
            }
        }
        merged.append(current)

        return merged
    }

    // MARK: - Word Breakdown

    /// Build word entries for an entire segment with estimated time ranges per word.
    public func wordsForSegment(_ segment: TranscriptEntry) -> [(index: Int, word: String, timeRange: CMTimeRange)] {
        let words = segment.text.split(separator: " ").map(String.init)
        let totalWords = max(words.count, 1)
        let segmentDuration = segment.endTime - segment.startTime
        let wordDuration = segmentDuration / Double(totalWords)

        return words.enumerated().map { index, word in
            let startTime = segment.startTime + (Double(index) / Double(totalWords)) * segmentDuration
            let cmStart = CMTime(seconds: startTime, preferredTimescale: 600)
            let cmDuration = CMTime(seconds: wordDuration, preferredTimescale: 600)
            return (index: index, word: word, timeRange: CMTimeRange(start: cmStart, duration: cmDuration))
        }
    }
}
