import Foundation

/// Shared audio activity state for cross-package use.
/// ScreenRecorder (VoomApp) writes to this, MeetingDetectionService (VoomMeetings) reads from it.
public final class AudioActivityTracker: Sendable {
    public static let shared = AudioActivityTracker()

    /// Last time system audio was detected. Thread-safe via nonisolated(unsafe) + atomic semantics.
    public nonisolated(unsafe) var lastSystemAudioActivity: Date = Date()

    private init() {}

    /// Call from any thread to update the last audio activity timestamp.
    nonisolated public func recordActivity() {
        lastSystemAudioActivity = Date()
    }
}
