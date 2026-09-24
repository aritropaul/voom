import Foundation

/// Tells the user speaking apart from remote audio leaking into their microphone.
///
/// Without headphones the mic re-records what the speakers play — a little later and
/// quieter — so mic-track speech alone doesn't mean the user spoke. That echo is the
/// system audio scaled by a gain that only changes when the setup does (speaker volume,
/// mic gain, putting headphones on). A span is echo when that gain, applied to the
/// system audio, accounts for the mic's energy; the user talking — alone, over, or
/// straight after a remote participant — leaves most of it unexplained. On headphones
/// the gain is ~0 and every mic word stays the user's.
public struct EchoBleedDetector: Sendable {
    /// Envelope resolution.
    public static let frameDuration: TimeInterval = 0.02
    /// Largest offset searched between the tracks: speaker output latency plus the skew
    /// between when the two reference files started.
    static let maxLag: TimeInterval = 1.0
    /// The echo gain is re-estimated per block, from the audio within `gainContext` of it,
    /// so switching between speakers and headphones mid-meeting is followed.
    static let gainBlock: TimeInterval = 10
    static let gainContext: TimeInterval = 30
    /// Share of a span's mic energy the echo must explain for the span to be echo; the
    /// rest is the user talking. Low because the gain is deliberately underestimated
    /// (see `gains`): on synthetic speech, echo spans leave at most ~70% of their energy
    /// unexplained while the user's own words leave 77–100%.
    static let explainedEnergy: Float = 0.25
    /// System audio below this RMS is silence — there is nothing to leak.
    static let silenceRMS: Float = 0.003
    /// How long the room keeps ringing after the system audio stops, in frames.
    static let tailFrames = 3

    let micEnvelope: [Float]
    let systemEnvelope: [Float]
    /// Frames by which the mic trails the system audio across the whole recording.
    let lag: Int
    /// Echo power gain (mic power per unit of system power) for each `gainBlock`.
    let gains: [Float]

    public init(micEnvelope: [Float], systemEnvelope: [Float]) {
        self.micEnvelope = micEnvelope
        self.systemEnvelope = systemEnvelope
        let maxLag = Int(Self.maxLag / Self.frameDuration)
        // Only frames where the system is playing: elsewhere the mic carries the user
        // alone, which would swamp a faint echo.
        let playing = systemEnvelope.indices.filter { systemEnvelope[$0] >= Self.silenceRMS }
        let lag = (-maxLag...maxLag).max { a, b in
            Self.correlation(micEnvelope, systemEnvelope, lag: a, systemFrames: playing)
                < Self.correlation(micEnvelope, systemEnvelope, lag: b, systemFrames: playing)
        } ?? 0
        self.lag = lag
        gains = Self.gains(mic: micEnvelope, system: systemEnvelope, lag: lag)
    }

    /// Build a detector from the meeting's mic and system reference tracks.
    public static func load(micURL: URL, systemURL: URL) throws -> EchoBleedDetector {
        EchoBleedDetector(
            micEnvelope: try envelope(of: micURL),
            systemEnvelope: try envelope(of: systemURL)
        )
    }

    /// True when mic activity over `start..<end` is best explained as system audio
    /// leaking back in rather than the user speaking.
    public func isEcho(start: TimeInterval, end: TimeInterval) -> Bool {
        guard let unexplained = unexplainedEnergy(start: start, end: end) else { return false }
        return unexplained <= 1 - Self.explainedEnergy
    }

    /// True when the system audio is silent over `start..<end`: no remote participant can
    /// have said anything there, so speech in the mixed recording came through the mic.
    public func systemIsSilent(start: TimeInterval, end: TimeInterval) -> Bool {
        let first = max(Int(start / Self.frameDuration), 0)
        let last = min(max(Int((end / Self.frameDuration).rounded(.up)), first + 1), systemEnvelope.count)
        guard first < last else { return false }
        return systemEnvelope[first..<last].allSatisfy { $0 < Self.silenceRMS }
    }

    /// Share of the span's mic energy the echo can't account for, or nil when there is
    /// no mic audio to judge.
    func unexplainedEnergy(start: TimeInterval, end: TimeInterval) -> Float? {
        let first = max(Int(start / Self.frameDuration), 0)
        let last = min(max(Int((end / Self.frameDuration).rounded(.up)), first + 1), micEnvelope.count)
        guard first < last else { return nil }

        let blockFrames = Int(Self.gainBlock / Self.frameDuration)
        var micEnergy: Float = 0, unexplained: Float = 0
        for t in first..<last {
            let mic = micEnvelope[t] * micEnvelope[t]
            let gain = gains[min(t / blockFrames, gains.count - 1)]
            // Also the few frames before: the room keeps ringing after the system audio
            // stops, and the lag can drift by a frame.
            let system = ((t - lag - Self.tailFrames)...(t - lag + 1))
                .map { systemEnvelope.indices.contains($0) ? systemEnvelope[$0] * systemEnvelope[$0] : 0 }
                .max() ?? 0
            micEnergy += mic
            unexplained += max(0, mic - gain * system)
        }
        guard micEnergy > 0 else { return nil }
        return unexplained / micEnergy
    }

    // MARK: - Estimation

    /// Per-block echo gain: a low percentile of mic/system power over the loud system
    /// frames near the block. Loud frames keep syllable edges and noise out of it; the
    /// low percentile picks frames where the user is quiet, so their own speech doesn't
    /// inflate it. Underestimating only makes the detector more conservative.
    private static func gains(mic: [Float], system: [Float], lag: Int) -> [Float] {
        let blockFrames = Int(gainBlock / frameDuration), context = Int(gainContext / frameDuration)
        let blocks = max((mic.count + blockFrames - 1) / blockFrames, 1)
        return (0..<blocks).map { block in
            let lo = max(block * blockFrames - context, max(lag, 0))
            let hi = min((block + 1) * blockFrames + context, mic.count, system.count + lag)
            guard lo < hi else { return 0 }
            let playing = (lo..<hi).filter { system[$0 - lag] >= silenceRMS }
            guard playing.count >= 50 else { return 0 }
            let loudest = playing.sorted { system[$0 - lag] > system[$1 - lag] }.prefix(playing.count / 2)
            let ratios = loudest.map { t -> Float in
                let s = system[t - lag]
                return (mic[t] * mic[t]) / (s * s)
            }.sorted()
            return ratios[ratios.count * 3 / 10]
        }
    }

    // MARK: - Envelope

    /// RMS loudness per `frameDuration` of a file, streamed at 16 kHz.
    static func envelope(of url: URL) throws -> [Float] {
        var envelope = LoudnessEnvelope(sampleRate: AudioChunkReader.sampleRate)
        try AudioChunkReader.read(url) { envelope.append($0) }
        return envelope.values
    }

    /// Pearson correlation of mic[t + lag] against system[t] over `systemFrames`.
    /// A positive lag means the mic hears the system audio later.
    static func correlation(_ mic: [Float], _ system: [Float], lag: Int, systemFrames: [Int]) -> Float {
        var n: Float = 0, sumMic: Float = 0, sumSystem: Float = 0
        for t in systemFrames where mic.indices.contains(t + lag) {
            n += 1
            sumMic += mic[t + lag]
            sumSystem += system[t]
        }
        guard n > 1 else { return 0 }
        let meanMic = sumMic / n, meanSystem = sumSystem / n
        var covariance: Float = 0, varianceMic: Float = 0, varianceSystem: Float = 0
        for t in systemFrames where mic.indices.contains(t + lag) {
            let dm = mic[t + lag] - meanMic, ds = system[t] - meanSystem
            covariance += dm * ds
            varianceMic += dm * dm
            varianceSystem += ds * ds
        }
        let denominator = (varianceMic * varianceSystem).squareRoot()
        return denominator > 0 ? covariance / denominator : 0
    }
}

/// Accumulates an RMS envelope, one value per `EchoBleedDetector.frameDuration`, from
/// samples arriving in arbitrarily sized chunks.
struct LoudnessEnvelope {
    private(set) var values: [Float] = []
    private let frameLength: Int
    private var sumOfSquares: Float = 0
    private var count = 0

    init(sampleRate: Double) {
        frameLength = Int(sampleRate * EchoBleedDetector.frameDuration)
    }

    mutating func append(_ samples: [Float]) {
        for sample in samples {
            sumOfSquares += sample * sample
            count += 1
            if count == frameLength {
                values.append((sumOfSquares / Float(frameLength)).squareRoot())
                sumOfSquares = 0
                count = 0
            }
        }
    }
}
