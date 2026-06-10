import Foundation

/// Shared audio activity state for cross-package use.
/// ScreenRecorder (VoomApp) writes to this, MeetingDetectionService (VoomMeetings) reads from it.
/// Writes arrive from SCStream callback threads, reads from arbitrary actors —
/// a lock keeps the Date from ever being read torn.
public final class AudioActivityTracker: Sendable {
    public static let shared = AudioActivityTracker()

    private nonisolated(unsafe) var _lastSystemAudioActivity: Date = Date()
    private let lock = NSLock()

    public var lastSystemAudioActivity: Date {
        lock.withLock { _lastSystemAudioActivity }
    }

    private init() {}

    /// Call from any thread to update the last audio activity timestamp.
    nonisolated public func recordActivity() {
        lock.withLock { _lastSystemAudioActivity = Date() }
    }
}
