import Foundation
import CoreGraphics

// MARK: - Recording Mode

enum RecordingMode: String, Codable, CaseIterable, Hashable {
    case fullScreen
    case region
    case cameraOnly
}

// MARK: - Codable CGRect

struct CodableCGRect: Codable, Hashable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

// MARK: - Chapter

struct Chapter: Codable, Hashable, Identifiable {
    var id: UUID
    var timestamp: TimeInterval
    var title: String

    init(timestamp: TimeInterval, title: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.title = title
    }
}

// MARK: - Recording Tag

struct RecordingTag: Codable, Hashable, Identifiable {
    var id: UUID
    var name: String
    var colorHex: String

    init(name: String, colorHex: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
    }
}

// MARK: - Transcript Entry

struct TranscriptEntry: Codable, Hashable, Identifiable {
    var id: UUID
    var startTime: TimeInterval
    var endTime: TimeInterval
    var text: String

    init(startTime: TimeInterval, endTime: TimeInterval, text: String) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
    }
}

// MARK: - Recording

struct Recording: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var createdAt: Date
    var duration: TimeInterval
    var fileURL: URL
    var thumbnailURL: URL?
    var fileSize: Int64
    var width: Int
    var height: Int
    var hasWebcam: Bool
    var hasSystemAudio: Bool
    var hasMicAudio: Bool
    var isTranscribed: Bool
    var isTranscribing: Bool
    var transcriptSegments: [TranscriptEntry]
    var summary: String?

    // Sharing
    var shareURL: URL?
    var shareCode: String?
    var shareExpiresAt: Date?
    var sharePassword: String?
    var ctaURL: URL?
    var ctaText: String?

    // Recording mode & region
    var recordingMode: RecordingMode?
    var cropRect: CodableCGRect?

    // Organization
    var folderID: UUID?
    var tags: [RecordingTag]?

    // Chapters
    var chapters: [Chapter]?

    // View notification tracking
    var lastNotifiedViewCount: Int?

    var isShared: Bool {
        shareURL != nil && shareExpiresAt != nil
    }

    var isShareExpired: Bool {
        guard let expiresAt = shareExpiresAt else { return false }
        return expiresAt < Date()
    }

    var shareExpiryDescription: String? {
        guard let expiresAt = shareExpiresAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if expiresAt < Date() {
            return "Expired \(formatter.localizedString(for: expiresAt, relativeTo: Date()))"
        }
        return "Expires \(formatter.localizedString(for: expiresAt, relativeTo: Date()))"
    }

    init(
        title: String,
        fileURL: URL,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        width: Int = 0,
        height: Int = 0,
        hasWebcam: Bool = false,
        hasSystemAudio: Bool = false,
        hasMicAudio: Bool = false,
        recordingMode: RecordingMode? = nil
    ) {
        self.id = UUID()
        self.title = title
        self.createdAt = Date()
        self.duration = duration
        self.fileURL = fileURL
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.hasWebcam = hasWebcam
        self.hasSystemAudio = hasSystemAudio
        self.hasMicAudio = hasMicAudio
        self.isTranscribed = false
        self.isTranscribing = false
        self.transcriptSegments = []
        self.summary = nil
        self.shareURL = nil
        self.shareCode = nil
        self.shareExpiresAt = nil
        self.sharePassword = nil
        self.ctaURL = nil
        self.ctaText = nil
        self.recordingMode = recordingMode
        self.cropRect = nil
        self.folderID = nil
        self.tags = nil
        self.chapters = nil
    }
}
