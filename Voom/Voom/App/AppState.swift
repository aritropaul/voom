import SwiftUI
import ScreenCaptureKit
import EventKit

struct DetectedMeeting {
    let eventIdentifier: String
    let title: String
    let startDate: Date
    let endDate: Date

    var timeRangeString: String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return "\(formatter.string(from: startDate)) – \(formatter.string(from: endDate))"
    }
}

struct UpcomingMeeting {
    let title: String
    let startDate: Date
    let endDate: Date
    let meetingURL: URL?
    let serviceName: String?

    var statusLabel: String {
        let now = Date()
        if now >= startDate && now <= endDate { return "Now" }
        let minutes = max(1, Int(ceil(startDate.timeIntervalSince(now) / 60)))
        return "Upcoming in \(minutes) min"
    }
}

enum RecordingState: Equatable {
    case idle
    case preparing
    case recording
    case paused
    case stopping
}

enum PiPPosition: String, CaseIterable {
    case bottomLeft, bottomRight, topLeft, topRight

    var label: String {
        switch self {
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        }
    }
}

@Observable @MainActor
final class AppState {
    var recordingState: RecordingState = .idle
    var isPanelVisible: Bool = false
    var isCameraEnabled: Bool = true
    var isMicEnabled: Bool = true
    var isSystemAudioEnabled: Bool = true
    var pipPosition: PiPPosition = .bottomRight
    var selectedDisplay: SCDisplay?
    var availableDisplays: [SCDisplay] = []
    var recordingDuration: TimeInterval = 0
    var currentRecordingURL: URL?
    var selectedRecordingID: UUID?
    var recordingMode: RecordingMode = .fullScreen
    var selectedRegion: CGRect?
    var isAnnotating: Bool = false
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "HasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "HasCompletedOnboarding") }
    }
    var meetingDetectionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "MeetingDetectionEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "MeetingDetectionEnabled") }
    }
    var detectedMeeting: DetectedMeeting?
    var upcomingMeeting: UpcomingMeeting?
    var isMeetingRecording: Bool = false

    var isRecording: Bool { recordingState == .recording }
    var canStartRecording: Bool { recordingState == .idle }
    var canStopRecording: Bool { recordingState == .recording || recordingState == .paused }

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
