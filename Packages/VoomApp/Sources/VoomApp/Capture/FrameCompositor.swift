import Foundation
import CoreImage
import CoreVideo
import VoomCore

public final class FrameCompositor: @unchecked Sendable {
    private let ciContext: CIContext
    private let screenSize: CGSize
    private let pipPosition: PiPPosition
    private let pipDiameter: CGFloat = 280
    private let pipMargin: CGFloat = 32

    public init(screenSize: CGSize, pipPosition: PiPPosition) {
        self.screenSize = screenSize
        self.pipPosition = pipPosition
        self.ciContext = CIContext(options: [
            .useSoftwareRenderer: false,
            .highQualityDownsample: true
        ])
    }

    public func composite(screenBuffer: CVPixelBuffer, cameraBuffer: CVPixelBuffer?) -> CVPixelBuffer? {
        let screenImage = CIImage(cvPixelBuffer: screenBuffer)

        guard let cameraBuffer else {
            return screenBuffer
        }

        let rawCamera = CIImage(cvPixelBuffer: cameraBuffer)

        // Mirror camera horizontally (selfie mirror)
        let cameraImage = rawCamera.transformed(by: CGAffineTransform(scaleX: -1, y: 1)
            .translatedBy(x: -rawCamera.extent.width, y: 0))

        // Scale camera to PiP size
        let cameraExtent = cameraImage.extent
        let scale = pipDiameter / min(cameraExtent.width, cameraExtent.height)
        let scaledCamera = cameraImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        // Center crop to square
        let scaledExtent = scaledCamera.extent
        let cropX = scaledExtent.midX - pipDiameter / 2
        let cropY = scaledExtent.midY - pipDiameter / 2
        let croppedCamera = scaledCamera.cropped(to: CGRect(x: cropX, y: cropY, width: pipDiameter, height: pipDiameter))

        // Create circular mask using CIRadialGradient
        let radius = pipDiameter / 2
        let maskCenter = CIVector(x: croppedCamera.extent.midX, y: croppedCamera.extent.midY)

        guard let radialGradient = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": maskCenter,
            "inputRadius0": radius - 1,
            "inputRadius1": radius,
            "inputColor0": CIColor.white,
            "inputColor1": CIColor.clear
        ])?.outputImage else {
            return screenBuffer
        }

        // Apply mask to camera
        let mask = radialGradient.cropped(to: croppedCamera.extent)

        guard let maskedCamera = CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: croppedCamera,
            kCIInputBackgroundImageKey: CIImage.empty(),
            kCIInputMaskImageKey: mask
        ])?.outputImage else {
            return screenBuffer
        }

        // Calculate position
        let position = pipOrigin(in: screenSize)

        // Translate masked camera to position
        let translatedCamera = maskedCamera.transformed(by: CGAffineTransform(
            translationX: position.x - croppedCamera.extent.origin.x,
            y: position.y - croppedCamera.extent.origin.y
        ))

        // Composite over screen
        let composited = translatedCamera.composited(over: screenImage)

        // Render to pixel buffer
        var outputBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: Int(screenSize.width),
            kCVPixelBufferHeightKey as String: Int(screenSize.height),
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, Int(screenSize.width), Int(screenSize.height),
                           kCVPixelFormatType_32BGRA, attrs as CFDictionary, &outputBuffer)

        guard let output = outputBuffer else { return screenBuffer }

        ciContext.render(composited, to: output)
        return output
    }

    private func pipOrigin(in size: CGSize) -> CGPoint {
        switch pipPosition {
        case .bottomLeft:
            return CGPoint(x: pipMargin, y: pipMargin)
        case .bottomRight:
            return CGPoint(x: size.width - pipDiameter - pipMargin, y: pipMargin)
        case .topLeft:
            return CGPoint(x: pipMargin, y: size.height - pipDiameter - pipMargin)
        case .topRight:
            return CGPoint(x: size.width - pipDiameter - pipMargin, y: size.height - pipDiameter - pipMargin)
        }
    }
}
