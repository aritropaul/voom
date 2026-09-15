import CoreMedia
import Testing
@testable import VoomCore

struct CameraFrameTimingTests {
    @Test func clampsFasterThanDeviceAllowsToMinDuration() {
        let minDuration = CMTime(value: 1, timescale: 30)
        let maxDuration = CMTime(value: 1, timescale: 15)
        let result = CameraFrameTiming.clampedDuration(
            desiredFPS: 60,
            minDuration: minDuration,
            maxDuration: maxDuration
        )
        #expect(CMTimeCompare(result, minDuration) == 0)
    }

    @Test func keepsRequestedRateWhenInsideRange() {
        let minDuration = CMTime(value: 1, timescale: 60)
        let maxDuration = CMTime(value: 1, timescale: 15)
        let result = CameraFrameTiming.clampedDuration(
            desiredFPS: 30,
            minDuration: minDuration,
            maxDuration: maxDuration
        )
        #expect(abs(result.seconds - (1.0 / 30.0)) < 0.0001)
    }
}
