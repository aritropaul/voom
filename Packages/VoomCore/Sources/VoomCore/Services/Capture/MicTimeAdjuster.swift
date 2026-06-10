import Foundation
import CoreMedia

/// Retimes mic sample buffers to a zero-based clock, subtracting accumulated
/// pause time. Shared by ScreenRecorder (VoomApp) and MeetingRecorder
/// (VoomMeetings) — keep changes here, not in per-recorder copies.
public final class MicTimeAdjuster: @unchecked Sendable {
    private var firstTime: CMTime?
    private var pauseStartTime: CMTime?
    private var accumulatedPause: CMTime = .zero
    private let lock = NSLock()

    public init() {}

    public func notifyPause() {
        lock.lock()
        if pauseStartTime == nil, let _ = firstTime {
            pauseStartTime = CMClockGetTime(CMClockGetHostTimeClock())
        }
        lock.unlock()
    }

    public func notifyResume() {
        lock.lock()
        if let pauseStart = pauseStartTime {
            let now = CMClockGetTime(CMClockGetHostTimeClock())
            accumulatedPause = CMTimeAdd(accumulatedPause, CMTimeSubtract(now, pauseStart))
            pauseStartTime = nil
        }
        lock.unlock()
    }

    public func retime(_ buffer: CMSampleBuffer) -> CMSampleBuffer? {
        let timestamp = CMSampleBufferGetPresentationTimeStamp(buffer)
        lock.lock()
        if firstTime == nil {
            firstTime = timestamp
        }
        guard let base = firstTime else { lock.unlock(); return nil }
        let pauseOffset = accumulatedPause
        lock.unlock()

        let adjusted = CMTimeSubtract(CMTimeSubtract(timestamp, base), pauseOffset)
        guard adjusted.seconds >= 0 else { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMSampleBufferGetDuration(buffer),
            presentationTimeStamp: adjusted,
            decodeTimeStamp: .invalid
        )
        var newBuffer: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil,
            sampleBuffer: buffer,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleBufferOut: &newBuffer
        )
        return newBuffer
    }
}
