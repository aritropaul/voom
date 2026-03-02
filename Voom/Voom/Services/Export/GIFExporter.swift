import Foundation
import AVFoundation
import ImageIO
import AppKit
import UniformTypeIdentifiers

actor GIFExporter {
    static let shared = GIFExporter()

    private let maxWidth: CGFloat = 640
    private let maxDuration: TimeInterval = 15
    private let fps: Double = 10

    private init() {}

    enum GIFError: LocalizedError {
        case noFrames
        case exportFailed(String)

        var errorDescription: String? {
            switch self {
            case .noFrames: return "No frames could be extracted."
            case .exportFailed(let msg): return "GIF export failed: \(msg)"
            }
        }
    }

    /// Export a video range as a GIF. Returns the GIF data.
    func exportGIF(
        from videoURL: URL,
        startTime: TimeInterval = 0,
        endTime: TimeInterval? = nil
    ) async throws -> Data {
        let asset = AVURLAsset(url: videoURL)
        let duration = try await asset.load(.duration).seconds
        let clampedEnd = min(endTime ?? maxDuration, startTime + maxDuration, duration)
        let totalFrames = Int((clampedEnd - startTime) * fps)
        guard totalFrames > 0 else { throw GIFError.noFrames }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.05, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.05, preferredTimescale: 600)

        // Extract frames
        var frames: [CGImage] = []
        for i in 0..<totalFrames {
            let time = CMTime(seconds: startTime + Double(i) / fps, preferredTimescale: 600)
            do {
                let (image, _) = try await generator.image(at: time)
                frames.append(image)
            } catch {
                continue
            }
        }

        guard !frames.isEmpty else { throw GIFError.noFrames }

        // Create GIF
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.gif.identifier as CFString,
            frames.count,
            nil
        ) else {
            throw GIFError.exportFailed("Could not create GIF destination.")
        }

        // GIF file properties (loop forever)
        let gifProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFLoopCount as String: 0
            ]
        ]
        CGImageDestinationSetProperties(destination, gifProperties as CFDictionary)

        // Frame properties
        let frameDelay = 1.0 / fps
        let frameProperties: [String: Any] = [
            kCGImagePropertyGIFDictionary as String: [
                kCGImagePropertyGIFDelayTime as String: frameDelay
            ]
        ]

        for frame in frames {
            CGImageDestinationAddImage(destination, frame, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFError.exportFailed("Failed to finalize GIF.")
        }

        return data as Data
    }

    /// Copy GIF data to the pasteboard.
    @MainActor
    func copyToClipboard(_ data: Data) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .init("com.compuserve.gif"))
    }

    /// Save GIF data via NSSavePanel.
    @MainActor
    func saveToFile(_ data: Data, suggestedName: String = "recording.gif") async -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.gif]
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true

        let response = await panel.begin()
        guard response == .OK, let url = panel.url else { return nil }

        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}
