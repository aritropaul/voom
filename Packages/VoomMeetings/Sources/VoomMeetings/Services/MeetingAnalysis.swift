import Foundation
import VoomCore

/// Meeting-specific analysis: action items, detailed summaries, meeting titles.
/// Uses Apple Foundation Models (macOS 26+) for on-device inference.
public actor MeetingAnalysis {
    public static let shared = MeetingAnalysis()
    private init() {}

    /// Extract action items from a meeting transcript with speaker labels.
    public func extractActionItems(from segments: [TranscriptEntry]) async -> [String] {
        let transcript = formatTranscriptForAnalysis(segments)
        guard !transcript.isEmpty else { return [] }

        let systemPrompt = """
        You are analyzing a meeting transcript. Extract clear, specific action items.
        Each action item should identify: what needs to be done, and who is responsible (if mentioned).
        Return one action item per line. No numbering, no bullet points, just the action item text.
        If there are no action items, return nothing.
        """

        let userPrompt = "Extract action items from this meeting transcript:\n\n\(transcript)"

        if let result = await TextAnalysisService.shared.generate(systemPrompt: systemPrompt, userPrompt: userPrompt) {
            return result
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
        return []
    }

    /// Generate a detailed meeting summary with speaker awareness.
    public func generateDetailedSummary(from segments: [TranscriptEntry]) async -> String? {
        let transcript = formatTranscriptForAnalysis(segments)
        guard transcript.split(separator: " ").count >= 10 else { return nil }

        let systemPrompt = """
        You are summarizing a meeting recording. Provide a concise but comprehensive summary.
        Focus on: key decisions made, topics discussed, and important points raised.
        Keep the summary to 2-4 sentences. Be direct and factual.
        Return only the summary text, no labels or formatting.
        """

        let userPrompt = "Summarize this meeting:\n\n\(transcript)"
        return await TextAnalysisService.shared.generate(systemPrompt: systemPrompt, userPrompt: userPrompt)
    }

    /// Generate a meeting-focused title from transcript.
    public func generateMeetingTitle(from segments: [TranscriptEntry]) async -> String? {
        let transcript = formatTranscriptForAnalysis(segments)
        guard transcript.split(separator: " ").count >= 5 else { return nil }

        let systemPrompt = """
        You are generating a short title for a meeting recording.
        The title should capture the main topic or purpose of the meeting.
        Return ONLY the title text — no quotes, no punctuation at the end, no explanation.
        Keep it under 8 words. Focus on the meeting topic, not greetings or small talk.
        """

        let userPrompt = "Generate a title for this meeting:\n\n\(transcript)"

        if let result = await TextAnalysisService.shared.generate(systemPrompt: systemPrompt, userPrompt: userPrompt) {
            // Take first non-empty line only
            return result
                .components(separatedBy: "\n")
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }

    private func formatTranscriptForAnalysis(_ segments: [TranscriptEntry]) -> String {
        segments.map { entry in
            if let speaker = entry.speaker {
                return "[\(speaker)] \(entry.text)"
            }
            return entry.text
        }.joined(separator: "\n")
    }
}
