import Foundation
import CoreMedia

/// Moves an audio sample buffer onto a different clock without disturbing how
/// long its samples last.
///
/// The obvious implementation — build one `CMSampleTimingInfo` with
/// `duration: CMSampleBufferGetDuration(buffer)` — is wrong. A single timing
/// entry describes *one sample* and is applied to all of them, so passing the
/// buffer's total duration tells CoreMedia that every individual sample lasts
/// as long as the whole buffer. For a 4096-frame buffer at 48 kHz that inflates
/// the buffer's span by 4096×.
///
/// Adapted from PR #3 by @vitaliiznak.
public enum AudioSampleTiming {

    /// Copy of `buffer` whose presentation timestamp is `presentationTime`, with
    /// every timing entry shifted by the same amount and all durations intact.
    /// Returns nil if the buffer carries no readable timing.
    public static func retime(_ buffer: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer? {
        var entryCount: CMItemCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &entryCount
        ) == noErr, entryCount > 0 else { return nil }

        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: entryCount)
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: entryCount, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return nil }

        // One constant shift across every entry: the buffer moves on the
        // timeline, its internal structure doesn't change.
        let shift = CMTimeSubtract(presentationTime, CMSampleBufferGetPresentationTimeStamp(buffer))
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, shift)
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, shift)
            }
        }

        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: buffer,
            sampleTimingEntryCount: entryCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &retimed
        ) == noErr else { return nil }
        return retimed
    }
}
