import Foundation
import ScreenCaptureKit
import VoomCore

/// Minimal headless conformer to `RecordingStateProvider` so the CLI can drive
/// the real `ScreenRecorder` without the app's UI state. `@MainActor` to match
/// how the recorder mutates it (the app's `AppState` is isolated the same way).
@MainActor
final class CLIStateProvider: RecordingStateProvider {
    var recordingState: RecordingState = .idle
    var isPanelVisible: Bool = false
    var isCameraEnabled: Bool = false
    var isMicEnabled: Bool = false
    var isSystemAudioEnabled: Bool = false
    var pipPosition: PiPPosition = .bottomRight
    var selectedDisplay: SCDisplay?
    var availableDisplays: [SCDisplay] = []
    var recordingDuration: TimeInterval = 0
    var currentRecordingURL: URL?
    var selectedRecordingID: UUID?
    var recordingMode: RecordingMode = .fullScreen
    var selectedRegion: CGRect?
    var isAnnotating: Bool = false
    var detectedMeeting: DetectedMeeting?
    var upcomingMeeting: UpcomingMeeting?
    var isMeetingRecording: Bool = false
    var meetingDetectionEnabled: Bool = false

    var isRecording: Bool { recordingState == .recording }
    var canStartRecording: Bool { recordingState == .idle }
    var canStopRecording: Bool { recordingState == .recording || recordingState == .paused }
    var formattedDuration: String {
        let total = Int(recordingDuration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
