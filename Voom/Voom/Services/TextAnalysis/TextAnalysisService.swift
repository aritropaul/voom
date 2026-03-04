import Foundation
@preconcurrency import FoundationModels
import os

private let logger = Logger(subsystem: "com.voom.app", category: "TextAnalysis")

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

    func generateChapters(from segments: [TranscriptEntry]) async -> [Chapter] {
        guard !segments.isEmpty else { return [] }

        let text = segments.enumerated().map { i, seg in
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            return "[\(String(format: "%d:%02d", m, s))] \(seg.text)"
        }.joined(separator: "\n")
        let truncated = String(text.prefix(8000))

        let result = await generate(
            system: "You generate chapter markers for video recordings. Given a timestamped transcript, identify 2-6 logical sections and return chapter markers. Each line must be exactly: TIMESTAMP|Title — where TIMESTAMP is in M:SS format. No other text.",
            user: "Generate chapter markers for this transcript:\n\n\(truncated)"
        ) ?? ""

        var chapters: [Chapter] = []
        for line in result.split(separator: "\n") {
            let parts = line.split(separator: "|", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let timeParts = parts[0].trimmingCharacters(in: .whitespaces).split(separator: ":")
            guard timeParts.count == 2,
                  let m = Int(timeParts[0]),
                  let s = Int(timeParts[1]) else { continue }
            let timestamp = TimeInterval(m * 60 + s)
            let title = String(parts[1]).trimmingCharacters(in: .whitespaces)
            chapters.append(Chapter(timestamp: timestamp, title: title))
        }
        return chapters
    }

    private func generate(system: String, user: String) async -> String? {
        guard #available(macOS 26.0, *) else { return nil }

        guard SystemLanguageModel.default.availability == .available else {
            logger.notice("[Voom] Apple Foundation Models not available")
            return nil
        }

        do {
            let session = LanguageModelSession(instructions: system)
            let response = try await session.respond(to: user)
            let text = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        } catch {
            logger.error("[Voom] Apple Foundation Models failed: \(error)")
            return nil
        }
    }
}
