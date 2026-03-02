import SwiftUI
import ScreenCaptureKit

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
    var hasCompletedOnboarding: Bool {
        get { UserDefaults.standard.bool(forKey: "HasCompletedOnboarding") }
        set { UserDefaults.standard.set(newValue, forKey: "HasCompletedOnboarding") }
    }

    var isRecording: Bool { recordingState == .recording }
    var canStartRecording: Bool { recordingState == .idle }
    var canStopRecording: Bool { recordingState == .recording || recordingState == .paused }

    var formattedDuration: String {
        let minutes = Int(recordingDuration) / 60
        let seconds = Int(recordingDuration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
