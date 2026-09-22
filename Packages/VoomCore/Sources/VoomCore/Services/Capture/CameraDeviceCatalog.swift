import Foundation
import AVFoundation

// MARK: - Camera Device

/// One selectable camera, as a value type safe to hold in UI state.
public struct CameraDevice: Identifiable, Hashable, Sendable {
    /// `AVCaptureDevice.uniqueID` — stable across reboots and app launches for a
    /// given machine, and what gets persisted.
    public let id: String
    /// Name to show, already disambiguated against same-named siblings.
    public let name: String
    public let isContinuityCamera: Bool

    public init(id: String, name: String, isContinuityCamera: Bool) {
        self.id = id
        self.name = name
        self.isContinuityCamera = isContinuityCamera
    }
}

// MARK: - Camera Device Catalog

/// Discovers cameras, disambiguates their names, and resolves a persisted
/// choice back to a live device.
public enum CameraDeviceCatalog {
    /// `.external` and `.continuityCamera` replaced the deprecated
    /// `.externalUnknown` in macOS 14. Desk View is deliberately absent: it is an
    /// additive second stream paired to a Continuity Camera, not an alternative
    /// to the main webcam, so listing it as a peer choice would mislead.
    static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .external,
        .continuityCamera
    ]

    /// Connected cameras, in discovery order.
    ///
    /// A fresh `DiscoverySession` per call is deliberate — this runs when a menu
    /// opens or a recording starts, not on a timer, and a cached session would
    /// be shared mutable state across actors for no benefit.
    public static func availableDevices() -> [CameraDevice] {
        let devices = discoveredDevices()
        let labels = disambiguate(names: devices.map { (id: $0.uniqueID, name: $0.localizedName) })
        return zip(devices, labels).map { device, label in
            CameraDevice(id: device.uniqueID, name: label, isContinuityCamera: device.isContinuityCamera)
        }
    }

    /// `localizedName` is not unique — two identical webcam models report the
    /// same string — so a shared name gets an id suffix to tell them apart.
    ///
    /// The suffix is the shortest one that actually distinguishes the clashing
    /// devices. A fixed length is not enough: UVC `uniqueID`s encode the USB
    /// location in the high bits and the vendor/product in the low bits, so two
    /// units of the same model differ at the front and share their tail. Falls
    /// back to an ordinal when even the full ids match.
    /// Pure, so the naming rule is testable without hardware.
    public static func disambiguate(names: [(id: String, name: String)]) -> [String] {
        var groups: [String: [String]] = [:]
        for entry in names {
            groups[entry.name, default: []].append(entry.id)
        }

        var suffixLengths: [String: Int] = [:]
        for (name, ids) in groups where ids.count > 1 {
            let longest = ids.map(\.count).max() ?? 0
            let distinguishing = (4...max(4, longest)).first { length in
                Set(ids.map { String($0.suffix(length)) }).count == ids.count
            }
            suffixLengths[name] = distinguishing ?? longest
        }

        var ordinals: [String: Int] = [:]
        return names.map { entry in
            guard let length = suffixLengths[entry.name] else { return entry.name }
            let ids = groups[entry.name] ?? []
            let suffixes = Set(ids.map { String($0.suffix(length)) })
            guard suffixes.count == ids.count else {
                // Indistinguishable ids: number them so the rows are at least
                // selectable, even if the labels aren't meaningful.
                let ordinal = (ordinals[entry.name] ?? 0) + 1
                ordinals[entry.name] = ordinal
                return "\(entry.name) (\(ordinal))"
            }
            return "\(entry.name) (\(entry.id.suffix(length)))"
        }
    }

    /// The device to open, given a persisted preference.
    ///
    /// Falls back deliberately rather than failing: a preference pointing at an
    /// unplugged webcam should still get the user a working camera. The caller
    /// can compare `uniqueID` against `preferredID` to tell whether it had to
    /// substitute.
    public static func resolve(preferredID: String?) -> AVCaptureDevice? {
        let devices = discoveredDevices()
        if let preferredID, let match = devices.first(where: { $0.uniqueID == preferredID }) {
            return match
        }
        // `systemPreferredCamera` already encodes Apple's own "next best
        // remembered device" history, so prefer it over guessing.
        if let system = AVCaptureDevice.systemPreferredCamera, system.isConnected {
            return system
        }
        if let fallback = AVCaptureDevice.default(for: .video) {
            return fallback
        }
        return devices.first
    }

    private static func discoveredDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices.filter(\.isConnected)
    }
}

// MARK: - Frame Rate Clamping

/// Picks a frame duration a capture format will actually accept.
///
/// Assigning `activeVideoMinFrameDuration` outside a format's supported ranges
/// raises an Objective-C `NSException`, which Swift cannot catch — it terminates
/// the app. External and virtual cameras routinely advertise ranges that exclude
/// the rate we want (a format pinned at 120 fps still reports
/// `maxFrameRate >= 60`), so the request is clamped into a real range first.
///
/// Split out from the `AVCaptureDevice.Format` extension because a `Format`
/// cannot be constructed in a test; this operates on plain values so the rule
/// itself is covered.
public enum FrameDurationClamp {
    /// The parts of `AVFrameRateRange` the clamping rule needs.
    public struct Range: Sendable {
        public let minFrameRate: Double
        public let maxFrameRate: Double
        public let minFrameDuration: CMTime
        public let maxFrameDuration: CMTime

        public init(minFrameRate: Double, maxFrameRate: Double, minFrameDuration: CMTime, maxFrameDuration: CMTime) {
            self.minFrameRate = minFrameRate
            self.maxFrameRate = maxFrameRate
            self.minFrameDuration = minFrameDuration
            self.maxFrameDuration = maxFrameDuration
        }

        /// Builds a range from frame rates alone, deriving the durations.
        public init(minFrameRate: Double, maxFrameRate: Double) {
            self.init(
                minFrameRate: minFrameRate,
                maxFrameRate: maxFrameRate,
                minFrameDuration: FrameDurationClamp.duration(forFPS: maxFrameRate),
                maxFrameDuration: FrameDurationClamp.duration(forFPS: minFrameRate)
            )
        }
    }

    /// Frame duration for a rate, keeping fractional rates like 29.97 exact.
    public static func duration(forFPS fps: Double) -> CMTime {
        guard fps > 0 else { return .invalid }
        return CMTime(value: 1_000_000, timescale: Int32((1_000_000 * fps).rounded()))
    }

    /// The duration to request, or nil when no range is usable.
    public static func duration(targetFPS: Double, ranges: [Range]) -> CMTime? {
        // Degenerate ranges do exist: virtual cameras report zeroes and
        // occasionally inverted bounds.
        let usable = ranges.filter {
            $0.minFrameRate > 0 && $0.maxFrameRate >= $0.minFrameRate
                && $0.minFrameDuration.isValid && $0.maxFrameDuration.isValid
        }
        guard !usable.isEmpty, targetFPS > 0 else { return nil }

        // Prefer a range that actually contains the target; otherwise take the
        // range whose ceiling sits closest to it.
        let containing = usable.first { targetFPS >= $0.minFrameRate && targetFPS <= $0.maxFrameRate }
        guard let chosen = containing ?? usable.min(by: {
            abs($0.maxFrameRate - targetFPS) < abs($1.maxFrameRate - targetFPS)
        }) else { return nil }

        let fps = min(max(targetFPS, chosen.minFrameRate), chosen.maxFrameRate)
        var result = duration(forFPS: fps)
        guard result.isValid else { return nil }

        // Clamp against the range's own CMTimes rather than trusting the
        // reciprocal: one tick past the boundary is still an out-of-range
        // assignment, and that is what raises the uncatchable exception.
        if CMTimeCompare(result, chosen.minFrameDuration) < 0 {
            result = chosen.minFrameDuration
        }
        if CMTimeCompare(result, chosen.maxFrameDuration) > 0 {
            result = chosen.maxFrameDuration
        }
        return result
    }
}

public extension AVCaptureDevice.Format {
    /// The frame duration to actually request for `targetFPS` on this format.
    /// See `FrameDurationClamp` for why this is never assigned raw.
    func clampedFrameDuration(targetFPS: Double) -> CMTime? {
        FrameDurationClamp.duration(
            targetFPS: targetFPS,
            ranges: videoSupportedFrameRateRanges.map {
                FrameDurationClamp.Range(
                    minFrameRate: $0.minFrameRate,
                    maxFrameRate: $0.maxFrameRate,
                    minFrameDuration: $0.minFrameDuration,
                    maxFrameDuration: $0.maxFrameDuration
                )
            }
        )
    }
}
