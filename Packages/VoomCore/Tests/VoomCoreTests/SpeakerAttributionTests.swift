import Testing
import AVFoundation
@testable import VoomCore

// MARK: - Helpers

private func token(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> VoomTranscriptToken {
    VoomTranscriptToken(text: text, startTime: start, endTime: end)
}

private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval) -> VoomTranscriptWord {
    VoomTranscriptWord(text: text, startTime: start, endTime: end, tokenRange: 0..<1)
}

/// Deterministic generator so synthetic audio is identical on every run.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Speech-like audio at 16 kHz: voiced syllables of varying loudness grouped into words,
/// separated by short gaps and longer pauses.
private func syntheticSpeech(seconds: Double, seed: UInt64, silentFrom: Double = .infinity) -> [Float] {
    let rate = 16_000.0
    var rng = SplitMix64(state: seed)
    var samples = [Float](repeating: 0, count: Int(seconds * rate))
    var t = 0.0
    while t < min(seconds, silentFrom) {
        for _ in 0..<Int.random(in: 1...3, using: &rng) {
            let length = Double.random(in: 0.12...0.25, using: &rng)
            let amplitude = Float.random(in: 0.1...0.4, using: &rng)
            let f0 = Double.random(in: 110...220, using: &rng)
            let first = Int(t * rate), count = Int(length * rate)
            for n in 0..<count where first + n < samples.count {
                let window = Float(sin(Double.pi * Double(n) / Double(count)))
                let phase = 2 * Double.pi * f0 * Double(n) / rate
                let voiced = Float(sin(phase) + 0.5 * sin(2 * phase))
                samples[first + n] = amplitude * window * (voiced + Float.random(in: -0.2...0.2, using: &rng))
            }
            t += length + Double.random(in: 0.03...0.08, using: &rng)
        }
        t += Double.random(in: 0.1...0.5, using: &rng)
    }
    return samples
}

/// What a laptop mic picks up from its own speakers: delayed, quieter, with a room tail.
private func speakerEcho(of audio: [Float], delay: Double, gain: Float) -> [Float] {
    let shift = Int(delay * 16_000), tail = 160
    var echo = [Float](repeating: 0, count: audio.count)
    for n in audio.indices {
        let source = n - shift
        let direct = source >= 0 && source < audio.count ? gain * audio[source] : 0
        echo[n] = direct + (n >= tail ? 0.5 * echo[n - tail] : 0)
    }
    return echo
}

private func noise(_ count: Int, level: Float, seed: UInt64) -> [Float] {
    var rng = SplitMix64(state: seed)
    return (0..<count).map { _ in Float.random(in: -level...level, using: &rng) }
}

private func mix(_ tracks: [Float]...) -> [Float] {
    var out = tracks[0]
    for track in tracks.dropFirst() { for i in out.indices { out[i] += track[i] } }
    return out
}

private func detector(mic: [Float], system: [Float]) -> EchoBleedDetector {
    var micEnvelope = LoudnessEnvelope(sampleRate: 16_000), systemEnvelope = LoudnessEnvelope(sampleRate: 16_000)
    micEnvelope.append(mic)
    systemEnvelope.append(system)
    return EchoBleedDetector(micEnvelope: micEnvelope.values, systemEnvelope: systemEnvelope.values)
}

/// Mic RMS over a span — spans quieter than speech wouldn't reach the mic's VAD.
private func micLevel(_ mic: [Float], _ start: Double, _ end: Double) -> Float {
    let slice = mic[Int(start * 16_000)..<min(Int(end * 16_000), mic.count)]
    return (slice.reduce(0) { $0 + $1 * $1 } / Float(max(slice.count, 1))).squareRoot()
}

/// Share of word-sized spans with audible mic activity that the detector calls echo.
private func echoRate(mic: [Float], system: [Float], where include: (Double) -> Bool = { _ in true }) -> Double {
    let d = detector(mic: mic, system: system)
    var echo = 0, total = 0
    for start in stride(from: 0.5, to: Double(mic.count) / 16_000 - 1, by: 0.25) where include(start + 0.15) {
        guard micLevel(mic, start, start + 0.3) > 0.005 else { continue }
        total += 1
        if d.isEcho(start: start, end: start + 0.3) { echo += 1 }
    }
    return Double(echo) / Double(max(total, 1))
}

// MARK: - Transcript Segmenter

struct TranscriptSegmenterTests {
    private let tokens = [
        token(" Hel", 0.0, 0.2), token("lo", 0.2, 0.4), token(" there", 0.4, 0.8), token(".", 0.8, 0.9),
        token(" How", 1.0, 1.2), token(" are", 1.2, 1.4), token(" you", 1.4, 1.6),
        token(" doing", 3.5, 3.9), token("?", 3.9, 4.0),
    ]

    @Test func groupsSubwordTokensIntoWords() {
        let words = TranscriptSegmenter.words(from: tokens)
        #expect(words.map(\.text) == ["Hello", "there.", "How", "are", "you", "doing?"])
        #expect(words[0].tokenRange == 0..<2)
        #expect(words[0].startTime == 0.0 && words[0].endTime == 0.4)
        #expect(words[1].tokenRange == 2..<4)
    }

    @Test func breaksAtPunctuationAndPauses() {
        let segments = TranscriptSegmenter.segments(from: tokens)
        #expect(segments.map(\.text) == ["Hello there.", "How are you", "doing?"])
        #expect(segments.allSatisfy { $0.speaker == nil })
    }

    @Test func capsSegmentsAtThirtyTokens() {
        let long = (0..<45).map { token(" w\($0)", Double($0) * 0.2, Double($0) * 0.2 + 0.15) }
        #expect(TranscriptSegmenter.segments(from: long).map { $0.text.split(separator: " ").count } == [30, 15])
    }

    @Test func splitsWhereTheSpeakerChanges() {
        let labels: [String?] = ["A", "A", "B", "B", "B", "A"]
        let segments = TranscriptSegmenter.segments(from: tokens, wordSpeakers: labels)
        #expect(segments.map(\.text) == ["Hello there.", "How are you", "doing?"])
        #expect(segments.map(\.speaker) == ["A", "B", "A"])

        let midSentence: [String?] = ["A", "B", "B", "B", "B", "B"]
        let split = TranscriptSegmenter.segments(from: tokens, wordSpeakers: midSentence)
        #expect(split.map(\.text) == ["Hello", "there.", "How are you", "doing?"])
        #expect(split.map(\.speaker) == ["A", "B", "B", "B"])
        #expect(split[0].endTime == 0.4 && split[1].startTime == 0.4)
    }
}

// MARK: - Speaker Attribution

struct SpeakerAttributionTests {
    private let segments = [
        SpeakerSegment(speaker: "Speaker 1", startTime: 0, endTime: 2),
        SpeakerSegment(speaker: "Speaker 2", startTime: 1.8, endTime: 4),
    ]

    @Test func picksTheSpeakerWithTheMostOverlap() {
        #expect(SpeakerAttribution.dominantSpeaker(for: word("a", 0.5, 0.9), in: segments) == "Speaker 1")
        #expect(SpeakerAttribution.dominantSpeaker(for: word("b", 1.9, 2.5), in: segments) == "Speaker 2")
        #expect(SpeakerAttribution.dominantSpeaker(for: word("c", 5.0, 5.3), in: segments) == nil)
    }

    @Test func zeroLengthWordsStillLandOnASpeaker() {
        #expect(SpeakerAttribution.dominantSpeaker(for: word("a", 1.0, 1.0), in: segments) == "Speaker 1")
        #expect(SpeakerAttribution.coverage(of: word("a", 1.0, 1.0), by: segments) == 1)
    }

    @Test func coverageSumsOverlappingSegments() {
        let you = [SpeakerSegment(speaker: "You", startTime: 0, endTime: 0.3), SpeakerSegment(speaker: "You", startTime: 0.5, endTime: 1)]
        #expect(abs(SpeakerAttribution.coverage(of: word("a", 0, 1), by: you) - 0.8) < 1e-9)
    }

    @Test func fillsGapsFromNearbyLabelsOnly() {
        let words = [word("a", 0, 0.3), word("b", 0.4, 0.6), word("c", 0.7, 0.9), word("d", 5, 5.3), word("e", 5.4, 5.6)]
        let resolved = SpeakerAttribution.resolve(["A", nil, nil, nil, "B"], words: words)
        #expect(resolved == ["A", "A", "A", "B", "B"])

        // Far from any label: stays unlabeled rather than inheriting a distant speaker.
        let far = [word("a", 0, 0.3), word("b", 3, 3.3), word("c", 6, 6.3)]
        #expect(SpeakerAttribution.resolve(["A", nil, "B"], words: far) == ["A", nil, "B"])
    }

    @Test func fillingDoesNotChainAcrossAPassage() {
        // Each gap word is 0.6s from the next: a chained fill would carry "A" to the end.
        let words = (0..<5).map { word("w\($0)", Double($0) * 0.9, Double($0) * 0.9 + 0.3) }
        #expect(SpeakerAttribution.resolve(["A", nil, nil, nil, nil], words: words) == ["A", "A", nil, nil, nil])
    }

    @Test func smoothsLoneOneWordFlips() {
        let words = (0..<5).map { word("w\($0)", Double($0) * 0.3, Double($0) * 0.3 + 0.25) }
        #expect(SpeakerAttribution.resolve(["A", "A", "B", "A", "A"], words: words) == ["A", "A", "A", "A", "A"])
        // A real turn change is kept.
        #expect(SpeakerAttribution.resolve(["A", "A", "B", "B", "A"], words: words) == ["A", "A", "B", "B", "A"])
    }
}

// MARK: - Echo Bleed

struct EchoBleedDetectorTests {
    private let seconds = 120.0
    private let remote = syntheticSpeech(seconds: 120, seed: 1)
    private let user = syntheticSpeech(seconds: 120, seed: 2)
    private let floor = noise(Int(120 * 16_000), level: 0.002, seed: 3)

    /// Remote and user alternate five-second turns.
    private func isRemoteTurn(_ t: Double) -> Bool { Int(t / 5) % 2 == 0 }
    private func turns(_ audio: [Float], remote: Bool) -> [Float] {
        audio.enumerated().map { isRemoteTurn(Double($0.offset) / 16_000) == remote ? $0.element : 0 }
    }
    /// Spans not straddling a turn change.
    private func insideTurn(_ t: Double) -> Bool {
        let offset = t.truncatingRemainder(dividingBy: 5)
        return offset > 0.3 && offset < 4.7
    }

    @Test func headphonesNeverFlagEcho() {
        #expect(echoRate(mic: mix(user, floor), system: remote) == 0)
        #expect(echoRate(mic: mix(turns(user, remote: false), floor), system: turns(remote, remote: true)) == 0)
    }

    @Test func flagsSpeakerBleed() {
        #expect(echoRate(mic: mix(speakerEcho(of: remote, delay: 0.15, gain: 0.1), floor), system: remote) > 0.95)
        // The mic file may start before or after the system file.
        #expect(echoRate(mic: mix(speakerEcho(of: remote, delay: -0.2, gain: 0.1), floor), system: remote) > 0.95)
    }

    @Test func keepsTheUserInTurnTakingOnSpeakers() {
        let remoteTurns = turns(remote, remote: true)
        let mic = mix(turns(user, remote: false), speakerEcho(of: remoteTurns, delay: 0.15, gain: 0.1), floor)
        #expect(echoRate(mic: mic, system: remoteTurns) { !isRemoteTurn($0) && insideTurn($0) } < 0.02)
        #expect(echoRate(mic: mic, system: remoteTurns) { isRemoteTurn($0) && insideTurn($0) } > 0.95)
    }

    @Test func keepsTheUserTalkingOverRemoteSpeech() {
        let mic = mix(user, speakerEcho(of: remote, delay: 0.15, gain: 0.1), floor)
        #expect(echoRate(mic: mic, system: remote) < 0.05)
    }

    @Test func reportsWhenTheSystemAudioIsSilent() {
        let remoteTurns = turns(remote, remote: true)
        let d = detector(mic: mix(turns(user, remote: false), floor), system: remoteTurns)
        // 5–10 s is the user's turn: nothing plays through the system audio.
        #expect(d.systemIsSilent(start: 6.0, end: 6.4))
        // Somewhere in the remote's first turn it is talking.
        #expect(stride(from: 0.5, to: 4.5, by: 0.25).contains { !d.systemIsSilent(start: $0, end: $0 + 0.3) })
    }

    @Test func envelopeIsIndependentOfChunking() {
        var whole = LoudnessEnvelope(sampleRate: 16_000), chunked = LoudnessEnvelope(sampleRate: 16_000)
        let audio = Array(remote.prefix(50_000))
        whole.append(audio)
        for start in stride(from: 0, to: audio.count, by: 777) {
            chunked.append(Array(audio[start..<min(start + 777, audio.count)]))
        }
        #expect(whole.values == chunked.values)
        #expect(whole.values.count == 50_000 / 320)
    }
}

// MARK: - Audio Chunk Reader

struct AudioChunkReaderTests {
    @Test func streamsStereoFilesAsSixteenKilohertzMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("voom-reader-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }

        // 3 s of a 440 Hz tone at 48 kHz stereo, identical in both channels.
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames = AVAudioFrameCount(3 * 48_000)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            for n in 0..<Int(frames) {
                buffer.floatChannelData![channel][n] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(n) / 48_000))
            }
        }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }

        var samples: [Float] = []
        var chunks = 0
        try AudioChunkReader.read(url, chunkDuration: 1) { chunk in
            samples += chunk
            chunks += 1
        }
        #expect(chunks >= 3)
        #expect(abs(samples.count - 3 * 16_000) < 200)
        // A 0.5 sine has RMS ~0.354; downmixing identical channels must not halve or double it.
        let middle = samples[8_000..<40_000]
        let rms = (middle.reduce(0) { $0 + $1 * $1 } / Float(middle.count)).squareRoot()
        #expect(abs(rms - 0.354) < 0.03)
    }
}
