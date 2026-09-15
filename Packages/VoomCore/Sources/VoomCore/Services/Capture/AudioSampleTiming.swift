import CoreMedia

/// Moves audio to the recording clock without changing the duration of each PCM frame.
public enum AudioSampleTiming {
    public static func retime(_ buffer: CMSampleBuffer, to presentationTime: CMTime) -> CMSampleBuffer? {
        let originalTime = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard originalTime.isNumeric, presentationTime.isNumeric else { return nil }
        var count = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count
        ) == noErr, count > 0 else { return nil }

        var timings = [CMSampleTimingInfo](repeating: .invalid, count: count)
        guard CMSampleBufferGetSampleTimingInfoArray(
            buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: nil
        ) == noErr else { return nil }
        let offset = CMTimeSubtract(presentationTime, originalTime)
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isNumeric {
                timings[index].presentationTimeStamp = CMTimeAdd(timings[index].presentationTimeStamp, offset)
            }
            if timings[index].decodeTimeStamp.isNumeric {
                timings[index].decodeTimeStamp = CMTimeAdd(timings[index].decodeTimeStamp, offset)
            }
        }

        var output: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: buffer, sampleTimingEntryCount: count,
            sampleTimingArray: &timings, sampleBufferOut: &output
        ) == noErr else { return nil }
        return output
    }
}
