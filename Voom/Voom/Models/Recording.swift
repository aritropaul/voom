import Foundation

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

    // Sharing
    var shareURL: URL?
    var shareCode: String?
    var shareExpiresAt: Date?

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
        hasMicAudio: Bool = false
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
        self.shareURL = nil
        self.shareCode = nil
        self.shareExpiresAt = nil
    }
}
