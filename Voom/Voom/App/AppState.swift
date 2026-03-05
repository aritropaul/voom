import SwiftUI
import ScreenCaptureKit
import EventKit
import VoomCore

@Observable @MainActor
final class AppState: RecordingStateProvider {
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
