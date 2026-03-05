import Foundation

// MARK: - Video Quality Preset

public struct VideoQualityPreset: Sendable {
    public let fps: Int
    public let bitRate: Int
    public let gopLength: Int
    public let enableBFrames: Bool
    public let downscaleFactor: CGFloat // 1.0 = native retina, 0.5 = half resolution

    public init(fps: Int, bitRate: Int, gopLength: Int, enableBFrames: Bool, downscaleFactor: CGFloat) {
        self.fps = fps
        self.bitRate = bitRate
        self.gopLength = gopLength
        self.enableBFrames = enableBFrames
        self.downscaleFactor = downscaleFactor
    }

    /// Screen recording: 60fps, 8mbps, retina quality
    public static let screenRecording = VideoQualityPreset(
        fps: 60,
        bitRate: 8_000_000,
        gopLength: 240,
        enableBFrames: true,
        downscaleFactor: 1.0
    )

    /// Meeting recording: 30fps, 4mbps, HD/2K (downscale from retina)
    public static let meeting = VideoQualityPreset(
        fps: 30,
        bitRate: 4_000_000,
        gopLength: 120,
        enableBFrames: true,
        downscaleFactor: 0.5
    )
}

// MARK: - Audio Track Mode

public enum AudioTrackMode: Sendable {
    /// Single mixed audio track (system + mic combined)
    case mixed
    /// Separate audio tracks for system audio and mic (used for speaker diarization)
    case separate
}
