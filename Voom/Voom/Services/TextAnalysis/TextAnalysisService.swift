import Foundation
@preconcurrency import FoundationModels

actor TextAnalysisService {
    static let shared = TextAnalysisService()

    func generateTitle(from segments: [TranscriptEntry]) async -> String {
        let earlySegments = segments.filter { $0.startTime < 120 }
        guard !earlySegments.isEmpty else { return "" }

        let text = earlySegments.map { $0.text }.joined(separator: " ")
        let truncated = String(text.prefix(2000))

        return await generate(
            system: "Generate a short descriptive title (3-8 words) for this recording based on its transcript. Return only the title, no quotes or punctuation.",
            user: truncated
        ) ?? ""
    }

    func generateSummary(from segments: [TranscriptEntry]) async -> String {
        guard !segments.isEmpty else { return "" }

        let text = segments.map { $0.text }.joined(separator: " ")
        let truncated = String(text.prefix(8000))

        return await generate(
            system: "You write short first-person summaries of recording transcripts. Always use \"I\" — never say \"the speaker\" or \"the user\".",
            user: "Write a 2-3 sentence first-person summary of this transcript. Start with \"I\":\n\n\(truncated)"
        ) ?? ""
    }

    private func generate(system: String, user: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }

        guard SystemLanguageModel.default.availability == .available else {
            NSLog("[Voom] Apple Foundation Models not available")
            return nil
        }

        do {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            NSLog("[Voom] Apple Foundation Models failed: %@", "\(error)")
            return nil
        }
    }
}
