import AVFoundation
import CoreMedia
import Testing
@testable import VoomCore

struct MicPCMConversionTests {
    @Test(arguments: [16_000.0, 24_000.0, 44_100.0, 96_000.0])
    func streamingConversionPreservesDurationAndBufferContinuity(sampleRate: Double) throws {
        let source = signal(frequency: 2_000, sampleRate: sampleRate, seconds: 1)
        let whole = try #require(MicPCMConverter().mono48k(floats: source, channels: 1, sampleRate: sampleRate))
        let converter = MicPCMConverter()
        var chunked = [Float]()
        for offset in stride(from: 0, to: source.count, by: 317) {
            let chunk = Array(source[offset..<min(offset + 317, source.count)])
            chunked += try #require(converter.mono48k(floats: chunk, channels: 1, sampleRate: sampleRate))
        }

        #expect(whole.count == 48_000)
        #expect(chunked.count == whole.count)
        #expect(zip(whole, chunked).allSatisfy { abs($0 - $1) < 0.000001 })
    }

    @Test func headsetConversionPreservesUpperSpeechAndSuppressesImages() throws {
        // Linear interpolation muffles this speech band and leaves an image at 16k - 5.4k.
        let source = signal(frequency: 5_400, sampleRate: 16_000, seconds: 0.2)
        let output = try #require(MicPCMConverter().mono48k(floats: source, channels: 1, sampleRate: 16_000))
        let settled = output.suffix(4_800)
        #expect(amplitude(of: 5_400, in: settled) > 0.095)
        #expect(amplitude(of: 10_600, in: settled) < 0.001)
    }

    @Test func downsamplingRejectsFrequenciesAboveNyquist() throws {
        // 30 kHz must not fold into an audible 18 kHz tone at the 48 kHz output rate.
        let source = signal(frequency: 30_000, sampleRate: 96_000, seconds: 0.2)
        let output = try #require(MicPCMConverter().mono48k(floats: source, channels: 1, sampleRate: 96_000))
        #expect(amplitude(of: 18_000, in: output.suffix(4_800)) < 0.001)
    }

    @Test func nativeRateDownmixPreservesSamples() throws {
        let source: [Float] = [0.5, -0.5, 0.25, 0.75]
        let output = try #require(MicPCMConverter().mono48k(floats: source, channels: 2, sampleRate: 48_000))
        #expect(output == [0, 0.5])
    }

    @Test func sampleBufferReportsOneFloatPerAudioFrame() throws {
        let buffer = try #require(MicPCM.sampleBuffer(
            floats: [0.1, -0.2, 0.3, -0.4], sampleRate: 48_000, presentationTime: CMTime(value: 2, timescale: 1)
        ))
        let data = try #require(CMSampleBufferGetDataBuffer(buffer))
        #expect(CMSampleBufferGetNumSamples(buffer) == 4)
        #expect(CMSampleBufferGetSampleSize(buffer, at: 0) == MemoryLayout<Float>.size)
        #expect(CMSampleBufferGetTotalSampleSize(buffer) == CMBlockBufferGetDataLength(data))
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer) == CMTime(value: 2, timescale: 1))
    }

    private func signal(frequency: Double, sampleRate: Double, seconds: Double) -> [Float] {
        (0..<Int(sampleRate * seconds)).map {
            Float(0.1 * sin(2 * Double.pi * frequency * Double($0) / sampleRate))
        }
    }

    private func amplitude(of frequency: Double, in samples: ArraySlice<Float>) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            let phase = 2 * Double.pi * frequency * Double(index) / 48_000
            real += Double(sample) * cos(phase)
            imaginary += Double(sample) * sin(phase)
        }
        return 2 * sqrt(real * real + imaginary * imaginary) / Double(samples.count)
    }
}
