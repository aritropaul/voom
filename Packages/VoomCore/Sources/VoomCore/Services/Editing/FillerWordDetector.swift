import Foundation
import CoreMedia

public struct FillerDetection: Identifiable, Sendable {
    public let id = UUID()
    public let word: String
    public let segmentID: UUID
    public let estimatedTimeRange: CMTimeRange
    public var isSelected: Bool = true

    public init(word: String, segmentID: UUID, estimatedTimeRange: CMTimeRange, isSelected: Bool = true) {
        self.word = word
        self.segmentID = segmentID
        self.estimatedTimeRange = estimatedTimeRange
        self.isSelected = isSelected
    }
}

public actor FillerWordDetector {
    public static let shared = FillerWordDetector()

    private let fillerWords: Set<String> = [
        "um", "uh", "uhm", "hmm",
        "like", "you know", "basically",
        "actually", "literally", "so",
        "I mean", "kind of", "sort of",
        "right", "okay so"
    ]

    public func detect(in segments: [TranscriptEntry]) -> [FillerDetection] {
        var detections: [FillerDetection] = []

        for segment in segments {
            let text = segment.text.lowercased()
            let words = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
            let totalWords = words.count
            guard totalWords > 0 else { continue }

            let segmentDuration = segment.endTime - segment.startTime

            for (index, word) in words.enumerated() {
                let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
                if fillerWords.contains(cleaned) {
                    let wordFraction = Double(index) / Double(totalWords)
                    let estimatedStart = segment.startTime + (wordFraction * segmentDuration)
                    let wordDuration = segmentDuration / Double(totalWords)

                    let timeRange = CMTimeRange(
                        start: CMTime(seconds: estimatedStart, preferredTimescale: 600),
                        duration: CMTime(seconds: wordDuration, preferredTimescale: 600)
                    )

                    detections.append(FillerDetection(
                        word: cleaned,
                        segmentID: segment.id,
                        estimatedTimeRange: timeRange
                    ))
                }
            }

            // Multi-word fillers
            let multiWordFillers = ["you know", "I mean", "kind of", "sort of", "okay so"]
            for filler in multiWordFillers {
                var searchRange = text.startIndex..<text.endIndex
                while let range = text.range(of: filler, range: searchRange) {
                    let beforeCount = text[text.startIndex..<range.lowerBound]
                        .components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }.count
                    let fillerWordCount = filler.components(separatedBy: " ").count
                    let wordFraction = Double(beforeCount) / Double(totalWords)
                    let estimatedStart = segment.startTime + (wordFraction * segmentDuration)
                    let wordDuration = segmentDuration * Double(fillerWordCount) / Double(totalWords)

                    let timeRange = CMTimeRange(
                        start: CMTime(seconds: estimatedStart, preferredTimescale: 600),
                        duration: CMTime(seconds: wordDuration, preferredTimescale: 600)
                    )

                    detections.append(FillerDetection(
                        word: filler,
                        segmentID: segment.id,
                        estimatedTimeRange: timeRange
                    ))

                    searchRange = range.upperBound..<text.endIndex
                }
            }
        }

        return detections.sorted { $0.estimatedTimeRange.start < $1.estimatedTimeRange.start }
    }
}
