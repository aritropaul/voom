import AVFoundation
import CoreMedia
import Testing
@testable import VoomCore

struct AudioSampleTimingTests {
    @Test(arguments: [16_000.0, 24_000.0, 48_000.0])
    func retimingPreservesPCMFrameAndBufferDuration(sampleRate: Double) throws {
        let input = try #require(MicPCM.sampleBuffer(
            floats: [Float](repeating: 0.1, count: 480), sampleRate: sampleRate,
            presentationTime: CMTime(value: 10, timescale: 1)
        ))
        let output = try #require(AudioSampleTiming.retime(input, to: .zero))
        var timing = CMSampleTimingInfo.invalid
        #expect(CMSampleBufferGetSampleTimingInfo(output, at: 0, timingInfoOut: &timing) == noErr)
        #expect(timing.duration == CMTime(value: 1, timescale: CMTimeScale(sampleRate)))
        #expect(CMSampleBufferGetDuration(output) == CMSampleBufferGetDuration(input))
        #expect(CMSampleBufferGetPresentationTimeStamp(output) == .zero)
        #expect(CMSampleBufferGetPresentationTimeStamp(input) == CMTime(value: 10, timescale: 1))
    }

    @Test func microphonePacketsRemainAdjacentAfterRetiming() throws {
        let adjuster = MicTimeAdjuster()
        let first = try #require(MicPCM.sampleBuffer(
            floats: [Float](repeating: 0.1, count: 480), sampleRate: 48_000,
            presentationTime: CMTime(value: 480_000, timescale: 48_000)
        ))
        let second = try #require(MicPCM.sampleBuffer(
            floats: [Float](repeating: 0.2, count: 480), sampleRate: 48_000,
            presentationTime: CMTime(value: 480_480, timescale: 48_000)
        ))
        let firstOutput = try #require(adjuster.retime(first))
        let secondOutput = try #require(adjuster.retime(second))
        let firstEnd = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(firstOutput), CMSampleBufferGetDuration(firstOutput))
        #expect(firstEnd == CMSampleBufferGetPresentationTimeStamp(secondOutput))
        #expect(CMSampleBufferGetDuration(secondOutput) == CMTime(value: 480, timescale: 48_000))
    }

    @Test func retimingPreservesEveryTimingEntry() throws {
        let input = try #require(MicPCM.sampleBuffer(
            floats: [0.1, 0.2, 0.3], sampleRate: 48_000,
            presentationTime: CMTime(value: 480_000, timescale: 48_000)
        ))
        var timings = (0..<3).map { index in
            CMSampleTimingInfo(
                duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(value: Int64(480_000 + index), timescale: 48_000),
                decodeTimeStamp: .invalid
            )
        }
        var detailed: CMSampleBuffer?
        #expect(CMSampleBufferCreateCopyWithNewTiming(
            allocator: nil, sampleBuffer: input, sampleTimingEntryCount: timings.count,
            sampleTimingArray: &timings, sampleBufferOut: &detailed
        ) == noErr)
        let detailedInput = try #require(detailed)
        let output = try #require(AudioSampleTiming.retime(detailedInput, to: .zero))
        for index in 0..<3 {
            var timing = CMSampleTimingInfo.invalid
            #expect(CMSampleBufferGetSampleTimingInfo(output, at: index, timingInfoOut: &timing) == noErr)
            #expect(timing.duration == CMTime(value: 1, timescale: 48_000))
            #expect(timing.presentationTimeStamp == CMTime(value: Int64(index), timescale: 48_000))
            #expect(!timing.decodeTimeStamp.isValid)
        }
    }
}
