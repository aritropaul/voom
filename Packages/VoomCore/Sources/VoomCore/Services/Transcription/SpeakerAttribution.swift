import Foundation

/// A span of time a diarizer attributes to one speaker. Spans of different speakers may overlap.
public struct SpeakerSegment: Sendable, Equatable {
    public let speaker: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(speaker: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.speaker = speaker
        self.startTime = startTime
        self.endTime = endTime
    }
}

/// Assigns diarization output to transcript words.
public enum SpeakerAttribution {
    /// Words shorter than this are widened around their midpoint before measuring
    /// overlap, so zero-length token timings still land on a speaker.
    static let minWordDuration: TimeInterval = 0.08

    /// Total time `word` overlaps `segments`.
    public static func overlap(of word: VoomTranscriptWord, with segments: [SpeakerSegment]) -> TimeInterval {
        let (start, end) = span(of: word)
        return segments.reduce(0) { total, segment in
            total + max(0, min(end, segment.endTime) - max(start, segment.startTime))
        }
    }

    /// Fraction of `word` covered by `segments`.
    public static func coverage(of word: VoomTranscriptWord, by segments: [SpeakerSegment]) -> Double {
        let (start, end) = span(of: word)
        return overlap(of: word, with: segments) / (end - start)
    }

    /// The speaker whose segments overlap `word` the most, or nil if none do.
    public static func dominantSpeaker(for word: VoomTranscriptWord, in segments: [SpeakerSegment]) -> String? {
        let (start, end) = span(of: word)
        var totals: [String: TimeInterval] = [:]
        for segment in segments {
            let overlap = min(end, segment.endTime) - max(start, segment.startTime)
            if overlap > 0 { totals[segment.speaker, default: 0] += overlap }
        }
        return totals.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// Clean up raw per-word labels before segmenting:
    /// - An unlabeled word borrows the label of the nearest originally-labeled word within
    ///   `fillDistance` (not chained, so a missing diarization can't spread one label
    ///   across a whole passage).
    /// - A lone word labeled differently from matching neighbours on both sides takes
    ///   theirs — a one-word speaker flip mid-sentence is diarization jitter, not a turn.
    public static func resolve(
        _ labels: [String?],
        words: [VoomTranscriptWord],
        fillDistance: TimeInterval = 1.0
    ) -> [String?] {
        precondition(labels.count == words.count, "one label per word")
        var resolved = labels

        for i in labels.indices where labels[i] == nil {
            var best: (label: String, distance: TimeInterval)?
            if let j = labels[..<i].lastIndex(where: { $0 != nil }) {
                best = (labels[j]!, words[i].startTime - words[j].endTime)
            }
            if let j = labels[(i + 1)...].firstIndex(where: { $0 != nil }) {
                let distance = words[j].startTime - words[i].endTime
                if best == nil || distance < best!.distance { best = (labels[j]!, distance) }
            }
            if let best, best.distance <= fillDistance { resolved[i] = best.label }
        }

        let filled = resolved
        for i in filled.indices.dropFirst().dropLast() {
            let before = filled[i - 1], after = filled[i + 1]
            if before != nil, before == after, filled[i] != before { resolved[i] = before }
        }

        return resolved
    }

    private static func span(of word: VoomTranscriptWord) -> (TimeInterval, TimeInterval) {
        guard word.endTime - word.startTime < minWordDuration else { return (word.startTime, word.endTime) }
        let mid = (word.startTime + word.endTime) / 2
        return (mid - minWordDuration / 2, mid + minWordDuration / 2)
    }
}
