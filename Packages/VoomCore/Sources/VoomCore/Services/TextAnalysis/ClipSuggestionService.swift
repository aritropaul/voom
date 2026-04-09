import Foundation

public struct ClipSuggestion: Identifiable, Sendable {
    public let id = UUID()
    public let title: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public var isSelected: Bool

    public var duration: TimeInterval { endTime - startTime }

    public init(title: String, startTime: TimeInterval, endTime: TimeInterval, isSelected: Bool = true) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.isSelected = isSelected
    }
}

extension TextAnalysisService {
    public func suggestClips(from segments: [TranscriptEntry]) async -> [ClipSuggestion] {
        guard !segments.isEmpty else { return [] }

        let maxSegments = 80
        let sampled: [TranscriptEntry]
        if segments.count > maxSegments {
            let step = Double(segments.count) / Double(maxSegments)
            sampled = (0..<maxSegments).map { i in segments[Int(Double(i) * step)] }
        } else {
            sampled = segments
        }
        let lastTime = segments.last?.endTime ?? segments.last?.startTime ?? 0
        let totalMinutes = Int(lastTime) / 60
        let totalSeconds = Int(lastTime) % 60

        let text = sampled.map { seg in
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return "[\(String(format: "%d:%02d", m, s))] \(seg.text)"
        }.joined(separator: "\n")

        let system = """
        You identify 3-5 key moments in a recording transcript that would make good standalone clips. \
        Each clip should capture a complete thought, important point, or interesting segment. \
        The recording is \(totalMinutes):\(String(format: "%02d", totalSeconds)) long. \
        Return each clip on its own line in this exact format: START_TIME|END_TIME|Title \
        where times are in M:SS format. No other text.
        """

        let result = await generate(
            systemPrompt: system,
            userPrompt: "Identify key clip-worthy moments:\n\n\(text)"
        ) ?? ""

        var clips: [ClipSuggestion] = []
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 2)
            guard parts.count == 3 else { continue }

            guard let startSeconds = parseTime(String(parts[0])),
                  let endSeconds = parseTime(String(parts[1])) else { continue }

            let title = String(parts[2]).trimmingCharacters(in: .whitespaces)
            guard endSeconds > startSeconds else { continue }

            clips.append(ClipSuggestion(
                title: title,
                startTime: startSeconds,
                endTime: min(endSeconds, lastTime)
            ))
        }

        return clips
    }

    private func parseTime(_ timeStr: String) -> TimeInterval? {
        let trimmed = timeStr.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: ":")
        guard parts.count == 2,
              let m = Int(parts[0]),
              let s = Int(parts[1]) else { return nil }
        return TimeInterval(m * 60 + s)
    }
}
