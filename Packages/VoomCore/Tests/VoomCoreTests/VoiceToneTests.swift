import Foundation
import Testing
@testable import VoomCore

struct VoiceToneTests {
    @Test(arguments: [44_100.0, 48_000.0], [false, true])
    func softensNasalMidsWithoutLosingBody(sampleRate: Double, headset: Bool) {
        // All bands share one gain detector. Independent normalized tones would hide EQ changes.
        let frequencies = [220.0, 800.0, 1_200.0, 3_000.0, 5_400.0]
        var samples = mixedSignal(frequencies: frequencies, amplitude: 0.025, seconds: 2, sampleRate: sampleRate)
        VoiceBeautifier(sampleRate: sampleRate, headset: headset).process(&samples)
        let settled = samples.suffix(Int(sampleRate / 2))
        let body = amplitude(of: 220, in: settled, sampleRate: sampleRate)
        let lowNasal = amplitude(of: 800, in: settled, sampleRate: sampleRate)
        let highNasal = amplitude(of: 1_200, in: settled, sampleRate: sampleRate)
        let clarity = amplitude(of: 3_000, in: settled, sampleRate: sampleRate)
        let high = amplitude(of: 5_400, in: settled, sampleRate: sampleRate)

        #expect(lowNasal / body < 0.8)
        #expect(highNasal / body < 0.8)
        #expect(body / clarity > 1.0)
        #expect(high / clarity < 1.05)
        #expect(body > 0.025)
    }

    @Test func recoversLevelGraduallyAfterLoudSpeech() {
        let sampleRate = 48_000.0
        let frequencies = [220.0, 1_000.0, 3_000.0]
        let beautifier = VoiceBeautifier(sampleRate: sampleRate)
        var loud = mixedSignal(frequencies: frequencies, amplitude: 0.18, seconds: 2, sampleRate: sampleRate)
        beautifier.process(&loud)
        var quiet = mixedSignal(frequencies: frequencies, amplitude: 0.02, seconds: 0.4, sampleRate: sampleRate)
        beautifier.process(&quiet)

        // Compare consecutive quiet passages, excluding the initial filter/compressor transient.
        let early = quiet[Int(sampleRate * 0.10)..<Int(sampleRate * 0.20)]
        let later = quiet[Int(sampleRate * 0.30)..<Int(sampleRate * 0.40)]
        let earlyBody = amplitude(of: 220, in: early, sampleRate: sampleRate)
        let laterBody = amplitude(of: 220, in: later, sampleRate: sampleRate)
        #expect(laterBody / earlyBody < 1.25)
    }

    @Test func processingKeepsTheSameToneAcrossBufferBoundaries() {
        let original = mixedSignal(frequencies: [220, 1_000, 3_000], amplitude: 0.05, seconds: 0.2, sampleRate: 48_000)
        var whole = original
        VoiceBeautifier(sampleRate: 48_000).process(&whole)

        let chunkedBeautifier = VoiceBeautifier(sampleRate: 48_000)
        var chunked = [Float]()
        for start in stride(from: 0, to: original.count, by: 317) {
            var chunk = Array(original[start..<min(start + 317, original.count)])
            chunkedBeautifier.process(&chunk)
            chunked.append(contentsOf: chunk)
        }
        #expect(zip(whole, chunked).allSatisfy { abs($0 - $1) < 0.000001 })
    }

    @Test func ordinarySpeechLevelsDoNotAcquireHarmonicDistortion() {
        let sampleRate = 48_000.0
        var samples = mixedSignal(frequencies: [440], amplitude: 0.12, seconds: 2, sampleRate: sampleRate)
        VoiceBeautifier(sampleRate: sampleRate).process(&samples)
        let settled = samples.suffix(24_000)
        let fundamental = amplitude(of: 440, in: settled, sampleRate: sampleRate)
        let harmonics = [880.0, 1_320.0, 1_760.0].map {
            amplitude(of: $0, in: settled, sampleRate: sampleRate)
        }
        #expect(fundamental > 0.08)
        #expect(harmonics.allSatisfy { $0 / fundamental < 0.001 })
    }

    @Test func loudInputStaysFiniteAndBelowClipping() {
        var samples = mixedSignal(frequencies: [220, 1_000, 3_000], amplitude: 0.4, seconds: 1, sampleRate: 48_000)
        VoiceBeautifier(sampleRate: 48_000).process(&samples)
        #expect(samples.allSatisfy { $0.isFinite && abs($0) < 1 })
    }

    private func mixedSignal(frequencies: [Double], amplitude: Double, seconds: Double, sampleRate: Double) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { frame in
            Float(frequencies.reduce(0.0) { sum, frequency in
                sum + amplitude * sin(2 * Double.pi * frequency * Double(frame) / sampleRate)
            })
        }
    }

    private func amplitude(of frequency: Double, in samples: ArraySlice<Float>, sampleRate: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (frame, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(frame) / sampleRate
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
}
