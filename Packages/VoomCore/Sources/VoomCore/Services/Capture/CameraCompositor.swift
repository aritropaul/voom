import Foundation
import CoreImage
import CoreVideo
import Metal
import os

private let compositorLogger = Logger(subsystem: "com.voom.app", category: "CameraCompositor")

/// Draws the camera feed into capture frames as a circular picture-in-picture.
///
/// Display-wide capture gets the webcam for free: the PiP is a real Voom window
/// and ScreenCaptureKit is told to except it back into the filter. Single-window
/// capture streams only the target window's own content, so there is no way to
/// let another window into the frame — the bubble has to be drawn here instead.
///
/// Confined to the capture queue: `composite` is only ever called from the
/// single serial `SCStreamOutput` handler queue, which is what makes the
/// unsynchronized `CIContext` and pool reuse safe.
public final class CameraCompositor: @unchecked Sendable {
    private let context: CIContext
    private let pool: CVPixelBufferPool
    private let outputSize: CGSize
    /// Circle the camera is masked to, in output pixel coordinates.
    private let bubbleRect: CGRect
    private let mask: CIImage

    /// Fails when Metal or the buffer pool is unavailable, in which case the
    /// caller should record without the bubble rather than not record at all.
    ///
    /// `scale` converts the design's point sizes to output pixels.
    public init?(width: Int, height: Int, pipPosition: PiPPosition, scale: CGFloat) {
        guard width > 0, height > 0 else { return nil }
        guard let device = MTLCreateSystemDefaultDevice() else {
            compositorLogger.error("No Metal device; recording without the camera bubble")
            return nil
        }

        // Skipping colour management keeps BGRA passing straight through, which
        // is both faster and avoids a colour shift against the uncomposited
        // frames of a display-wide recording.
        self.context = CIContext(mtlDevice: device, options: [
            .workingColorSpace: NSNull(),
            .cacheIntermediates: false
        ])

        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            // The encoder wants IOSurface-backed buffers; without this every
            // frame takes a CPU copy on its way into AVAssetWriter.
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        var createdPool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &createdPool)
        guard status == kCVReturnSuccess, let createdPool else {
            compositorLogger.error("Pixel buffer pool unavailable (\(status)); recording without the camera bubble")
            return nil
        }
        self.pool = createdPool
        self.outputSize = CGSize(width: width, height: height)
        self.bubbleRect = Self.bubbleFrame(
            outputSize: CGSize(width: width, height: height),
            pipPosition: pipPosition,
            scale: scale
        )
        self.mask = Self.circularMask(for: bubbleRect)
    }

    /// Where the bubble sits, in output pixels with a bottom-left origin to
    /// match Core Image.
    ///
    /// The on-screen PiP is a 240pt circle inset 32pt from the display edge. A
    /// window is usually far smaller than a display, so the same absolute size
    /// would swallow it — the diameter is capped at a third of the window's
    /// short side.
    static func bubbleFrame(outputSize: CGSize, pipPosition: PiPPosition, scale: CGFloat) -> CGRect {
        let scale = max(scale, 1)
        let shortSide = min(outputSize.width, outputSize.height)
        let diameter = min(240 * scale, shortSide / 3).rounded()
        let margin = min(32 * scale, (shortSide - diameter) / 2).rounded()

        let x: CGFloat
        let y: CGFloat
        switch pipPosition {
        case .bottomLeft:
            x = margin
            y = margin
        case .bottomRight:
            x = outputSize.width - diameter - margin
            y = margin
        case .topLeft:
            x = margin
            y = outputSize.height - diameter - margin
        case .topRight:
            x = outputSize.width - diameter - margin
            y = outputSize.height - diameter - margin
        }
        return CGRect(x: max(0, x), y: max(0, y), width: diameter, height: diameter)
    }

    /// Opaque inside the circle, transparent outside, with a one-pixel feather
    /// so the rim isn't aliased.
    private static func circularMask(for rect: CGRect) -> CIImage {
        let radius = Float(rect.width / 2)
        let gradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: rect.midX, y: rect.midY),
            "inputRadius0": max(radius - 1, 0),
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        ])
        return gradient?.outputImage?.cropped(to: rect) ?? CIImage(color: .white).cropped(to: rect)
    }

    /// Screen frame with the camera drawn over it, or nil if compositing fails —
    /// callers write the untouched screen frame in that case, because a
    /// recording missing its bubble beats a dropped frame.
    public func composite(screen: CVPixelBuffer, camera: CVPixelBuffer) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screen)
        guard let bubble = bubbleImage(from: camera) else { return nil }

        guard let blend = CIFilter(name: "CIBlendWithAlphaMask", parameters: [
            kCIInputBackgroundImageKey: screenImage,
            kCIInputImageKey: bubble,
            kCIInputMaskImageKey: mask
        ]), let output = blend.outputImage else { return nil }

        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }

        context.render(
            output.cropped(to: CGRect(origin: .zero, size: outputSize)),
            to: buffer
        )
        return buffer
    }

    /// Camera frame cropped square (aspect-fill, centre), mirrored to match the
    /// on-screen preview, and moved into the bubble's slot.
    private func bubbleImage(from camera: CVPixelBuffer) -> CIImage? {
        var image = CIImage(cvPixelBuffer: camera)
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return nil }

        // Aspect-fill: scale so the short side covers the bubble, then crop the
        // centre. Matches the preview's .resizeAspectFill.
        let scale = bubbleRect.width / min(extent.width, extent.height)
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let scaled = image.extent
        let cropOrigin = CGPoint(
            x: scaled.minX + (scaled.width - bubbleRect.width) / 2,
            y: scaled.minY + (scaled.height - bubbleRect.height) / 2
        )
        image = image.cropped(to: CGRect(origin: cropOrigin, size: bubbleRect.size))

        // The live PiP mirrors the camera, so the composited bubble mirrors it
        // too — a window recording should not look flipped next to a
        // full-screen one.
        image = image
            .transformed(by: CGAffineTransform(translationX: -image.extent.midX, y: -image.extent.midY))
            .transformed(by: CGAffineTransform(scaleX: -1, y: 1))
            .transformed(by: CGAffineTransform(translationX: bubbleRect.midX, y: bubbleRect.midY))

        return image
    }
}
