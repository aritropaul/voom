import Foundation
@preconcurrency import AVFoundation

/// Streams an audio file as 16 kHz mono Float samples, one chunk at a time, so hour-long
/// meeting tracks are never decoded into memory whole.
public enum AudioChunkReader {
    public static let sampleRate: Double = 16_000

    public enum ReadError: LocalizedError {
        case unsupportedFormat(URL)
        case conversionFailed(URL, Error?)

        public var errorDescription: String? {
            switch self {
            case .unsupportedFormat(let url):
                return "Can't convert \(url.lastPathComponent) to 16 kHz mono"
            case .conversionFailed(let url, let error):
                return "Couldn't decode \(url.lastPathComponent): \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }

    /// Decode `url`, downmixed to mono and resampled to 16 kHz, handing `body` roughly
    /// `chunkDuration` seconds of samples per call, in order.
    public static func read(
        _ url: URL,
        chunkDuration: TimeInterval = 10,
        _ body: ([Float]) throws -> Void
    ) throws {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ), let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw ReadError.unsupportedFormat(url)
        }
        // Without this a stereo input is reduced to its left channel.
        converter.downmix = true

        let input = FileInput(file: file, maxFrames: AVAudioFrameCount(inputFormat.sampleRate * chunkDuration))
        let outputCapacity = AVAudioFrameCount(sampleRate * chunkDuration) + 1024

        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
                throw ReadError.unsupportedFormat(url)
            }
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { packetCount, inputStatus in
                guard let buffer = input.next(packetCount) else {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputStatus.pointee = .haveData
                return buffer
            }

            if let readError = input.readError { throw ReadError.conversionFailed(url, readError) }
            if status == .error { throw ReadError.conversionFailed(url, conversionError) }
            if output.frameLength > 0, let channel = output.floatChannelData?[0] {
                try body(Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
            }
            if status == .endOfStream { return }
        }
    }
}

/// Feeds `AVAudioConverter` from an audio file. The converter's input block runs
/// synchronously inside `convert`, but the compiler can't see that — a reference box
/// carries the end-of-file state without an unsafe capture of local vars.
private final class FileInput: @unchecked Sendable {
    private let file: AVAudioFile
    private let maxFrames: AVAudioFrameCount
    private var reachedEnd = false
    private(set) var readError: Error?

    init(file: AVAudioFile, maxFrames: AVAudioFrameCount) {
        self.file = file
        self.maxFrames = maxFrames
    }

    /// The next buffer of up to `frames` frames, or nil at the end of the file.
    func next(_ frames: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard !reachedEnd,
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: min(frames, maxFrames))
        else { return nil }
        do {
            try file.read(into: buffer, frameCount: buffer.frameCapacity)
        } catch {
            // AVAudioFile.length overestimates packetized formats, so the final read can
            // throw after all real audio is in hand. Only a failure before any audio was
            // read is a genuinely unreadable file.
            if file.framePosition == 0 { readError = error }
            reachedEnd = true
            return nil
        }
        guard buffer.frameLength > 0 else {
            reachedEnd = true
            return nil
        }
        return buffer
    }
}
