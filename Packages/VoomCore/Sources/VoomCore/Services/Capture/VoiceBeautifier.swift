import Foundation

/// Gentle speech polish: remove rumble, retain body, soften nasal mids and S's.
public final class VoiceBeautifier: @unchecked Sendable {
    private var highPass: Biquad
    private var warmth: Biquad
    private var nasalMid: Biquad
    private var deEss: Biquad
    private var envelope: Float = 0
    private var inputPower: Float = 0
    private var agc: Float = 1
    private let attack: Float
    private let release: Float
    private let levelSmoothing: Float
    private let gainReduction: Float
    private let gainRecovery: Float
    private let threshold: Float = 0.22
    private let ratio: Float = 1.7
    private let targetRMS: Float = 0.12

    public init(sampleRate: Double, headset: Bool = false) {
        let sr = Float(max(sampleRate, 8_000))
        highPass = Biquad.highPass(freq: 70, q: 0.7, sampleRate: sr)
        warmth = Biquad.lowShelf(freq: 170, gainDB: headset ? 1.2 : 2.4, q: 0.7, sampleRate: sr)
        // A broad, modest cut reduces a honky tone without hollowing out the chest band.
        nasalMid = Biquad.peaking(freq: 1_000, gainDB: -2.8, q: 0.9, sampleRate: sr)
        deEss = Biquad.peaking(freq: min(7_600, sr * 0.45), gainDB: -2.2, q: 1.6, sampleRate: sr)
        attack = 1 - exp(-1 / (0.010 * sr))
        release = 1 - exp(-1 / (0.140 * sr))
        levelSmoothing = 1 - exp(-1 / (0.100 * sr))
        gainReduction = 1 - exp(-1 / (0.120 * sr))
        gainRecovery = 1 - exp(-1 / (1.500 * sr))
    }

    public func process(_ samples: UnsafeMutablePointer<Float>, count: Int) {
        for i in 0..<count {
            var x = highPass.process(samples[i])
            // Measure before tone shaping so level correction does not compensate for the EQ.
            let gain = smoothGain(for: x)
            x = warmth.process(x)
            x = nasalMid.process(x)
            x = deEss.process(x)
            x = compress(x) * gain
            samples[i] = softLimit(x)
        }
    }

    public func process(_ samples: inout [Float]) {
        samples.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            process(base, count: buffer.count)
        }
    }

    private func compress(_ sample: Float) -> Float {
        let level = abs(sample)
        if level > envelope {
            envelope += attack * (level - envelope)
        } else {
            envelope += release * (level - envelope)
        }
        guard envelope > threshold else { return sample }
        let compressed = threshold + (envelope - threshold) / ratio
        return sample * (compressed / envelope)
    }

    private func smoothGain(for sample: Float) -> Float {
        inputPower += levelSmoothing * (sample * sample - inputPower)
        let level = sqrt(max(inputPower, 0))
        // Hold the gain on quiet background sound; recover slowly between speech phrases.
        guard level > 0.02 else { return agc }
        let desired = min(max(targetRMS / level, 0.65), 1.5)
        let smoothing = desired < agc ? gainReduction : gainRecovery
        agc += smoothing * (desired - agc)
        return agc
    }

    private func softLimit(_ sample: Float) -> Float {
        let ceiling: Float = 0.94
        let magnitude = abs(sample)
        if magnitude <= ceiling { return sample }
        let sign: Float = sample < 0 ? -1 : 1
        let excess = magnitude - ceiling
        return min(max(sign * (ceiling + excess / (1 + excess * 12)), -0.99), 0.99)
    }
}

struct Biquad {
    var b0: Float
    var b1: Float
    var b2: Float
    var a1: Float
    var a2: Float
    var z1: Float = 0
    var z2: Float = 0

    mutating func process(_ x: Float) -> Float {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    static func highPass(freq: Float, q: Float, sampleRate: Float) -> Biquad {
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0 = (1 + cosw) / 2
        let b1 = -(1 + cosw)
        let b2 = (1 + cosw) / 2
        let a0 = 1 + alpha
        let a1 = -2 * cosw
        let a2 = 1 - alpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func peaking(freq: Float, gainDB: Float, q: Float, sampleRate: Float) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / (2 * q)
        let b0 = 1 + alpha * a
        let b1 = -2 * cosw
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw
        let a2 = 1 - alpha / a
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    static func lowShelf(freq: Float, gainDB: Float, q: Float, sampleRate: Float) -> Biquad {
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Float.pi * freq / sampleRate
        let cosw = cos(w0)
        let sinw = sin(w0)
        let alpha = sinw / 2 * sqrt((a + 1 / a) * (1 / q - 1) + 2)
        let twoSqrtAAlpha = 2 * sqrt(a) * alpha
        let b0 = a * ((a + 1) - (a - 1) * cosw + twoSqrtAAlpha)
        let b1 = 2 * a * ((a - 1) - (a + 1) * cosw)
        let b2 = a * ((a + 1) - (a - 1) * cosw - twoSqrtAAlpha)
        let a0 = (a + 1) + (a - 1) * cosw + twoSqrtAAlpha
        let a1 = -2 * ((a - 1) + (a + 1) * cosw)
        let a2 = (a + 1) + (a - 1) * cosw - twoSqrtAAlpha
        return Biquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }
}
