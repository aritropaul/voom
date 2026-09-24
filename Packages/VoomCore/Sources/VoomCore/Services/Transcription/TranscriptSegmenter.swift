import Foundation

/// A timed ASR sub-word token. Tokens that begin a word carry a leading space.
public struct VoomTranscriptToken: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// A word assembled from consecutive tokens.
public struct VoomTranscriptWord: Sendable, Equatable {
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    /// Indices of the tokens this word was built from.
    public let tokenRange: Range<Int>
}

/// Turns ASR token timings into words and sentence-like transcript segments.
public enum TranscriptSegmenter {
    /// A silence longer than this starts a new segment.
    static let maxGap: TimeInterval = 1.5
    /// Segments are cut after this many tokens.
    static let maxTokens = 30

    /// Group tokens into words: a token starting with whitespace (or SentencePiece's `▁`)
    /// begins a new word, anything else continues the current one.
    public static func words(from tokens: [VoomTranscriptToken]) -> [VoomTranscriptWord] {
        var words: [VoomTranscriptWord] = []
        var wordStart = 0
        for i in tokens.indices {
            let isLast = i == tokens.count - 1
            if isLast || beginsWord(tokens[i + 1].text) {
                let range = wordStart..<(i + 1)
                words.append(VoomTranscriptWord(
                    text: tokens[range].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
                    startTime: tokens[wordStart].startTime,
                    endTime: tokens[i].endTime,
                    tokenRange: range
                ))
                wordStart = i + 1
            }
        }
        return words
    }

    /// Group tokens into sentence-like segments. Breaks at sentence-ending punctuation,
    /// gaps longer than 1.5s, or after 30 tokens.
    ///
    /// With `wordSpeakers` — one label per entry of `words(from: tokens)` — a segment also
    /// ends wherever the speaker changes between words, and carries its speaker.
    public static func segments(
        from tokens: [VoomTranscriptToken],
        wordSpeakers: [String?]? = nil
    ) -> [VoomTranscriptSegment] {
        var tokenSpeakers: [String?]?
        if let wordSpeakers {
            let words = words(from: tokens)
            precondition(words.count == wordSpeakers.count, "one speaker label per word")
            var labels = [String?](repeating: nil, count: tokens.count)
            for (word, speaker) in zip(words, wordSpeakers) {
                for i in word.tokenRange { labels[i] = speaker }
            }
            tokenSpeakers = labels
        }

        var segments: [VoomTranscriptSegment] = []
        var segmentStart = 0

        for (i, token) in tokens.enumerated() {
            let isLast = i == tokens.count - 1
            let endsWithPunctuation = token.text.hasSuffix(".") || token.text.hasSuffix("?") || token.text.hasSuffix("!")
            let hasTimeGap = !isLast && (tokens[i + 1].startTime - token.endTime) > maxGap
            let tooManyTokens = i - segmentStart + 1 >= maxTokens
            // Tokens of one word share a label, so this only fires at word boundaries.
            let speakerChanges = !isLast && tokenSpeakers.map { $0[i] != $0[i + 1] } == true

            if isLast || endsWithPunctuation || hasTimeGap || tooManyTokens || speakerChanges {
                let text = tokens[segmentStart...i].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    segments.append(VoomTranscriptSegment(
                        startTime: tokens[segmentStart].startTime,
                        endTime: token.endTime,
                        text: text,
                        speaker: tokenSpeakers?[segmentStart]
                    ))
                }
                segmentStart = i + 1
            }
        }

        return segments
    }

    private static func beginsWord(_ text: String) -> Bool {
        guard let first = text.first else { return false }
        return first.isWhitespace || first == "\u{2581}"
    }
}
