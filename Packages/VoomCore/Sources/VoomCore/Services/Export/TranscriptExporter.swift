import Foundation
import AppKit
import UniformTypeIdentifiers

public actor TranscriptExporter {
    public static let shared = TranscriptExporter()
    private init() {}

    public enum Format: String, CaseIterable, Sendable {
        case srt = "SRT"
        case vtt = "VTT"
        case txt = "TXT"
        case json = "JSON"

        public var fileExtension: String {
            rawValue.lowercased()
        }

        public var contentType: UTType {
            switch self {
            case .srt: .plainText
            case .vtt: .plainText
            case .txt: .plainText
            case .json: .json
            }
        }
    }

    public func export(segments: [TranscriptEntry], format: Format) -> String {
        switch format {
        case .srt: return exportSRT(segments)
        case .vtt: return exportVTT(segments)
        case .txt: return exportTXT(segments)
        case .json: return exportJSON(segments)
        }
    }

    // MARK: - SRT

    private func exportSRT(_ segments: [TranscriptEntry]) -> String {
        segments.enumerated().map { index, seg in
            let start = formatSRTTime(seg.startTime)
            let end = formatSRTTime(seg.endTime)
            let text = seg.speaker.map { "[\($0)] \(seg.text)" } ?? seg.text
            return "\(index + 1)\n\(start) --> \(end)\n\(text)"
        }.joined(separator: "\n\n")
    }

    private func formatSRTTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    // MARK: - VTT

    private func exportVTT(_ segments: [TranscriptEntry]) -> String {
        var lines = ["WEBVTT", ""]
        for seg in segments {
            let start = formatVTTTime(seg.startTime)
            let end = formatVTTTime(seg.endTime)
            let text = seg.speaker.map { "[\($0)] \(seg.text)" } ?? seg.text
            lines.append("\(start) --> \(end)")
            lines.append(text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private func formatVTTTime(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        let ms = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    // MARK: - TXT

    private func exportTXT(_ segments: [TranscriptEntry]) -> String {
        segments.map { seg in
            let m = Int(seg.startTime) / 60
            let s = Int(seg.startTime) % 60
            let timestamp = String(format: "%d:%02d", m, s)
            if let speaker = seg.speaker {
                return "[\(timestamp)] [\(speaker)] \(seg.text)"
            }
            return "[\(timestamp)] \(seg.text)"
        }.joined(separator: "\n")
    }

    // MARK: - JSON

    private func exportJSON(_ segments: [TranscriptEntry]) -> String {
        let sorted = segments.sorted { $0.startTime < $1.startTime }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(sorted),
              let string = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return string
    }

    // MARK: - Save

    @MainActor
    public func saveToFile(_ content: String, format: Format, suggestedName: String) async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.nameFieldStringValue = "\(suggestedName).\(format.fileExtension)"
        panel.canCreateDirectories = true

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }
}
