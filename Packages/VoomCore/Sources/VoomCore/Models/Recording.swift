import Foundation
import CoreGraphics

// MARK: - Codable CGRect

public struct CodableCGRect: Codable, Hashable, Sendable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }

    public init(_ rect: CGRect) {
        self.x = rect.origin.x
        self.y = rect.origin.y
        self.width = rect.size.width
        self.height = rect.size.height
    }
}

// MARK: - Chapter

public struct Chapter: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var timestamp: TimeInterval
    public var title: String

    public init(timestamp: TimeInterval, title: String) {
        self.id = UUID()
        self.timestamp = timestamp
        self.title = title
    }
}

// MARK: - Recording Tag

public struct RecordingTag: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var colorHex: String

    public init(name: String, colorHex: String) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
    }
}

// MARK: - Transcript Entry

public struct TranscriptEntry: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var startTime: TimeInterval
    public var endTime: TimeInterval
    public var text: String
    public var speaker: String?

    public init(startTime: TimeInterval, endTime: TimeInterval, text: String, speaker: String? = nil) {
        self.id = UUID()
        self.startTime = startTime
        self.endTime = endTime
        self.text = text
        self.speaker = speaker
    }
}

// MARK: - Recording

public struct Recording: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var duration: TimeInterval
    public var fileURL: URL
    public var thumbnailURL: URL?
    public var fileSize: Int64
    public var width: Int
    public var height: Int
    public var hasWebcam: Bool
    public var hasSystemAudio: Bool
    public var hasMicAudio: Bool
    public var isTranscribed: Bool
    public var isTranscribing: Bool
    public var transcriptSegments: [TranscriptEntry]
    public var summary: String?

    // Sharing
    public var shareURL: URL?
    public var shareCode: String?
    public var shareExpiresAt: Date?
    public var sharePassword: String?
    public var ctaURL: URL?
    public var ctaText: String?

    // Recording mode & region
    public var recordingMode: RecordingMode?
    public var cropRect: CodableCGRect?

    // Organization
    public var folderID: UUID?
    public var tags: [RecordingTag]?

    // Chapters
    public var chapters: [Chapter]?

    // Meeting
    public var isMeeting: Bool?
    public var meetingActionItems: [String]?

    // View notification tracking
    public var lastNotifiedViewCount: Int?

    public var isShared: Bool {
        shareURL != nil && shareExpiresAt != nil
    }

    public var isShareExpired: Bool {
        guard let expiresAt = shareExpiresAt else { return false }
        return expiresAt < Date()
    }

    public var shareExpiryDescription: String? {
        guard let expiresAt = shareExpiresAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        if expiresAt < Date() {
            return "Expired \(formatter.localizedString(for: expiresAt, relativeTo: Date()))"
        }
        return "Expires \(formatter.localizedString(for: expiresAt, relativeTo: Date()))"
    }

    public init(
        title: String,
        fileURL: URL,
        duration: TimeInterval = 0,
        fileSize: Int64 = 0,
        width: Int = 0,
        height: Int = 0,
        hasWebcam: Bool = false,
        hasSystemAudio: Bool = false,
        hasMicAudio: Bool = false,
        recordingMode: RecordingMode? = nil,
        isMeeting: Bool? = nil
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
        self.isMeeting = isMeeting
        self.meetingActionItems = nil
    }
}
