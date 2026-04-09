import Foundation
import ScreenCaptureKit

// MARK: - Recording State

public enum RecordingState: Equatable, Sendable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
}

// MARK: - Recording Mode

public enum RecordingMode: String, Codable, CaseIterable, Hashable, Sendable {
    case fullScreen
    case region
    case cameraOnly
}

// MARK: - PiP Position

public enum PiPPosition: String, Codable, CaseIterable, Sendable {
    case bottomLeft, bottomRight, topLeft, topRight

    public var label: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

// MARK: - Detected Meeting

public struct DetectedMeeting: Sendable {
    public let eventIdentifier: String
    public let title: String
    public let startDate: Date
    public let endDate: Date

    public var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }

    public init(eventIdentifier: String, title: String, startDate: Date, endDate: Date) {
        self.eventIdentifier = eventIdentifier
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
    }
}

// MARK: - Notifications

public extension Notification.Name {
    static let seekToTimestamp = Notification.Name("com.voom.seekToTimestamp")
}

// MARK: - Upcoming Meeting

public struct UpcomingMeeting: Sendable {
    public let title: String
    public let startDate: Date
    public let endDate: Date
    public let meetingURL: URL?
    public let serviceName: String?

    public var statusLabel: String {
        let now = Date()
        if now >= startDate && now <= endDate { return "Now" }
        let minutes = max(1, Int(ceil(startDate.timeIntervalSince(now) / 60)))
        return "Upcoming in \(minutes) min"
    }

    public init(title: String, startDate: Date, endDate: Date, meetingURL: URL?, serviceName: String?) {
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.meetingURL = meetingURL
        self.serviceName = serviceName
    }
}
