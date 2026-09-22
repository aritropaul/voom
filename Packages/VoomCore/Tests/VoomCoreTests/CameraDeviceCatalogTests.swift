import Testing
import AVFoundation
@testable import VoomCore

struct CameraDeviceCatalogTests {

    // MARK: - Name Disambiguation

    @Test func uniqueNamesAreLeftAlone() {
        let labels = CameraDeviceCatalog.disambiguate(names: [
            (id: "0x1400000046d0825", name: "FaceTime HD Camera"),
            (id: "0x1400000046d0826", name: "Logitech BRIO")
        ])
        #expect(labels == ["FaceTime HD Camera", "Logitech BRIO"])
    }

    @Test func duplicateNamesGetADistinguishingIdSuffix() {
        // Two units of the same webcam model report the same localizedName AND
        // the same vendor/product tail — they differ only in the USB location at
        // the front of the id. A fixed-length suffix would label both rows
        // identically, which is the bug this case exists to prevent.
        let labels = CameraDeviceCatalog.disambiguate(names: [
            (id: "0x1400000046d0825", name: "Logitech BRIO"),
            (id: "0x1410000046d0825", name: "Logitech BRIO")
        ])
        #expect(labels[0] != labels[1])
        #expect(labels[0].hasPrefix("Logitech BRIO ("))
        #expect(labels[1].hasPrefix("Logitech BRIO ("))
    }

    @Test func identicalIdentifiersFallBackToOrdinals() {
        let labels = CameraDeviceCatalog.disambiguate(names: [
            (id: "same", name: "Cam"),
            (id: "same", name: "Cam")
        ])
        #expect(labels == ["Cam (1)", "Cam (2)"])
    }

    @Test func onlyTheDuplicatedNameIsSuffixed() {
        let labels = CameraDeviceCatalog.disambiguate(names: [
            (id: "aaaa1111", name: "Studio Cam"),
            (id: "bbbb2222", name: "Studio Cam"),
            (id: "cccc3333", name: "FaceTime HD Camera")
        ])
        #expect(labels[0] == "Studio Cam (1111)")
        #expect(labels[1] == "Studio Cam (2222)")
        #expect(labels[2] == "FaceTime HD Camera")
    }

    @Test func shortIdentifiersAreUsedWholeRatherThanTruncated() {
        let labels = CameraDeviceCatalog.disambiguate(names: [
            (id: "ab", name: "Cam"),
            (id: "cd", name: "Cam")
        ])
        #expect(labels == ["Cam (ab)", "Cam (cd)"])
    }

    @Test func orderIsPreserved() {
        let names = [
            (id: "1", name: "C"),
            (id: "2", name: "A"),
            (id: "3", name: "B")
        ]
        #expect(CameraDeviceCatalog.disambiguate(names: names) == ["C", "A", "B"])
    }

    @Test func emptyListProducesEmptyLabels() {
        #expect(CameraDeviceCatalog.disambiguate(names: []).isEmpty)
    }

    // MARK: - Device Types

    @Test func discoveryCoversExternalAndContinuityCamerasButNotDeskView() {
        // `.externalUnknown` is deprecated; Desk View is an additive second
        // stream rather than an alternative to the main webcam.
        #expect(CameraDeviceCatalog.deviceTypes.contains(.builtInWideAngleCamera))
        #expect(CameraDeviceCatalog.deviceTypes.contains(.external))
        #expect(CameraDeviceCatalog.deviceTypes.contains(.continuityCamera))
        #expect(!CameraDeviceCatalog.deviceTypes.contains(.deskViewCamera))
    }
}

// MARK: - Frame Duration Clamping

/// These exercise the real clamping rule (`FrameDurationClamp`) — the same code
/// path `AVCaptureDevice.Format.clampedFrameDuration` calls. The rule exists to
/// keep an out-of-range assignment from raising an uncatchable Objective-C
/// exception, so every case here is a range shape a real camera reports.
struct FrameDurationClampTests {

    private func fps(_ duration: CMTime?) -> Double? {
        guard let duration, duration.isValid, duration.seconds > 0 else { return nil }
        return 1.0 / duration.seconds
    }

    @Test func aTargetInsideTheRangeIsHonoured() {
        let ranges = [FrameDurationClamp.Range(minFrameRate: 1, maxFrameRate: 60)]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 60) < 0.01)
    }

    @Test func aCameraPinnedAboveTheTargetClampsUpInsteadOfCrashing() {
        // This is the crash case: maxFrameRate (120) passes a naive
        // `maxFrameRate >= target` check, but 60 is not in [120, 120], so
        // requesting 1/60 would raise an NSException.
        let ranges = [FrameDurationClamp.Range(minFrameRate: 120, maxFrameRate: 120)]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 120) < 0.01)
    }

    @Test func aCameraCappedBelowTheTargetClampsDown() {
        let ranges = [FrameDurationClamp.Range(minFrameRate: 15, maxFrameRate: 30)]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 30) < 0.01)
    }

    @Test func theRangeContainingTheTargetWinsOverACloserCeiling() {
        let ranges = [
            FrameDurationClamp.Range(minFrameRate: 120, maxFrameRate: 120),
            FrameDurationClamp.Range(minFrameRate: 1, maxFrameRate: 60)
        ]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 60) < 0.01)
    }

    @Test func resultAlwaysLandsInsideTheChosenRangeDurations() {
        // The invariant that actually matters: whatever comes back must satisfy
        // minFrameDuration <= result <= maxFrameDuration.
        let shapes: [(min: Double, max: Double)] = [
            (1, 30), (24, 30), (30, 30), (120, 120), (5, 240), (29.97, 29.97)
        ]
        for shape in shapes {
            let range = FrameDurationClamp.Range(minFrameRate: shape.min, maxFrameRate: shape.max)
            guard let result = FrameDurationClamp.duration(targetFPS: 60, ranges: [range]) else {
                Issue.record("no duration for range \(shape)")
                continue
            }
            #expect(CMTimeCompare(result, range.minFrameDuration) >= 0)
            #expect(CMTimeCompare(result, range.maxFrameDuration) <= 0)
        }
    }

    @Test func degenerateRangesAreRejectedRatherThanUsed() {
        // Virtual cameras report zeroes and inverted bounds; using either would
        // produce an invalid CMTime or an out-of-range assignment.
        #expect(FrameDurationClamp.duration(targetFPS: 60, ranges: []) == nil)
        #expect(FrameDurationClamp.duration(
            targetFPS: 60,
            ranges: [FrameDurationClamp.Range(minFrameRate: 0, maxFrameRate: 0)]
        ) == nil)
        #expect(FrameDurationClamp.duration(
            targetFPS: 60,
            ranges: [FrameDurationClamp.Range(minFrameRate: 60, maxFrameRate: 30)]
        ) == nil)
        #expect(FrameDurationClamp.duration(
            targetFPS: 0,
            ranges: [FrameDurationClamp.Range(minFrameRate: 1, maxFrameRate: 60)]
        ) == nil)
    }

    @Test func oneUsableRangeSurvivesAlongsideDegenerateOnes() {
        let ranges = [
            FrameDurationClamp.Range(minFrameRate: 0, maxFrameRate: 0),
            FrameDurationClamp.Range(minFrameRate: 1, maxFrameRate: 30)
        ]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 30) < 0.01)
    }

    @Test func fractionalRatesKeepTheirPrecision() {
        let ranges = [FrameDurationClamp.Range(minFrameRate: 29.97, maxFrameRate: 29.97)]
        let result = FrameDurationClamp.duration(targetFPS: 60, ranges: ranges)
        #expect(abs((fps(result) ?? 0) - 29.97) < 0.001)
    }
}
