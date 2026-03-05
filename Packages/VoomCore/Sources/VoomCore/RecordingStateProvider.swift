import Foundation
import ScreenCaptureKit

/// Protocol for AppState-like objects, allowing VoomApp and VoomMeetings
/// to interact with recording state without importing the concrete AppState.
@MainActor
public protocol RecordingStateProvider: AnyObject, Sendable {
    var recordingState: RecordingState { get set }
    var isPanelVisible: Bool { get set }
    var isCameraEnabled: Bool { get set }
    var isMicEnabled: Bool { get set }
    var isSystemAudioEnabled: Bool { get set }
    var pipPosition: PiPPosition { get set }
    var selectedDisplay: SCDisplay? { get set }
    var availableDisplays: [SCDisplay] { get set }
    var recordingDuration: TimeInterval { get set }
    var currentRecordingURL: URL? { get set }
    var selectedRecordingID: UUID? { get set }
    var recordingMode: RecordingMode { get set }
    var selectedRegion: CGRect? { get set }
    var isAnnotating: Bool { get set }
    var detectedMeeting: DetectedMeeting? { get set }
    var upcomingMeeting: UpcomingMeeting? { get set }
    var isMeetingRecording: Bool { get set }
    var meetingDetectionEnabled: Bool { get set }

    var isRecording: Bool { get }
    var canStartRecording: Bool { get }
    var canStopRecording: Bool { get }
    var formattedDuration: String { get }
}
