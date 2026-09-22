import Testing
import CoreVideo
import CoreGraphics
@testable import VoomCore

struct CameraCompositorTests {

    // MARK: - Bubble Geometry

    @Test func bubbleSitsInTheRequestedCornerWithTheDesignInset() {
        // 1000×1000 at scale 1: the design's 240pt circle and 32pt inset fit
        // outright, so they're used as-is.
        let rect = CameraCompositor.bubbleFrame(
            outputSize: CGSize(width: 1_000, height: 1_000),
            pipPosition: .bottomRight,
            scale: 1
        )
        #expect(rect == CGRect(x: 728, y: 32, width: 240, height: 240))
    }

    @Test func everyCornerLandsInsideTheFrame() {
        let size = CGSize(width: 1_600, height: 1_000)
        for position in PiPPosition.allCases {
            let rect = CameraCompositor.bubbleFrame(outputSize: size, pipPosition: position, scale: 2)
            #expect(rect.minX >= 0)
            #expect(rect.minY >= 0)
            #expect(rect.maxX <= size.width)
            #expect(rect.maxY <= size.height)
            #expect(rect.width == rect.height)
        }
    }

    @Test func aSmallWindowGetsASmallerBubbleRatherThanBeingSwallowed() {
        // A 300×300 window at 2x would take a 480px bubble at the design size —
        // larger than the window itself. It has to shrink instead.
        let rect = CameraCompositor.bubbleFrame(
            outputSize: CGSize(width: 300, height: 300),
            pipPosition: .bottomRight,
            scale: 2
        )
        #expect(rect.width <= 100)
        #expect(rect.maxX <= 300)
        #expect(rect.maxY <= 300)
    }

    @Test func aWideWindowSizesTheBubbleOffTheShortSide() {
        // Short side 200 → the cap (200/3 ≈ 66) governs, not the long side.
        let rect = CameraCompositor.bubbleFrame(
            outputSize: CGSize(width: 2_000, height: 200),
            pipPosition: .topLeft,
            scale: 1
        )
        #expect(rect.height <= 200 / 3 + 1)
        #expect(rect.maxY <= 200)
    }

    // MARK: - Actual Compositing

    private func makeBuffer(width: Int, height: Int, blue: UInt8, green: UInt8, red: UInt8) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            kCVPixelFormatType_32BGRA, attributes as CFDictionary, &buffer
        ) == kCVReturnSuccess, let buffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * stride + x * 4
                pixels[offset] = blue
                pixels[offset + 1] = green
                pixels[offset + 2] = red
                pixels[offset + 3] = 255
            }
        }
        return buffer
    }

    private func pixel(_ buffer: CVPixelBuffer, x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8) {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return (0, 0, 0) }
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let offset = y * stride + x * 4
        return (pixels[offset], pixels[offset + 1], pixels[offset + 2])
    }

    @Test func theBubbleIsDrawnInTheCornerTheUserChose() throws {
        // Core Image works bottom-left-origin while CVPixelBuffer rows run
        // top-down. Getting that backwards would silently mirror the bubble to
        // the opposite corner, so this asserts against real rendered pixels
        // rather than trusting the geometry math alone.
        let size = 400
        guard let compositor = CameraCompositor(
            width: size, height: size, pipPosition: .bottomLeft, scale: 1
        ) else {
            // No Metal device (headless CI) — nothing to assert against.
            return
        }
        let screen = try #require(makeBuffer(width: size, height: size, blue: 0, green: 0, red: 0))
        let camera = try #require(makeBuffer(width: 200, height: 200, blue: 0, green: 0, red: 255))

        let output = try #require(compositor.composite(screen: screen, camera: camera))
        #expect(CVPixelBufferGetWidth(output) == size)
        #expect(CVPixelBufferGetHeight(output) == size)

        let bubble = CameraCompositor.bubbleFrame(
            outputSize: CGSize(width: size, height: size), pipPosition: .bottomLeft, scale: 1
        )
        // Bottom-left in Core Image is the BOTTOM row band of the buffer, which
        // is the high y index once rows are read top-down.
        let centreX = Int(bubble.midX)
        let centreY = size - Int(bubble.midY)
        let centre = pixel(output, x: centreX, y: centreY)
        #expect(centre.r > 200, "bubble centre should carry the camera's red")
        #expect(centre.b < 60)

        // The opposite corner must be untouched screen content.
        let far = pixel(output, x: size - 5, y: 5)
        #expect(far.r < 20)
        #expect(far.g < 20)
        #expect(far.b < 20)
    }

    @Test func pixelsOutsideTheCircleStayAsScreenContent() throws {
        let size = 400
        guard let compositor = CameraCompositor(
            width: size, height: size, pipPosition: .bottomLeft, scale: 1
        ) else { return }
        let screen = try #require(makeBuffer(width: size, height: size, blue: 0, green: 0, red: 0))
        let camera = try #require(makeBuffer(width: 200, height: 200, blue: 0, green: 0, red: 255))
        let output = try #require(compositor.composite(screen: screen, camera: camera))

        let bubble = CameraCompositor.bubbleFrame(
            outputSize: CGSize(width: size, height: size), pipPosition: .bottomLeft, scale: 1
        )
        // The bubble's bounding-box corner lies outside the inscribed circle, so
        // the mask must have left it as screen content — this is what proves the
        // feed is a circle and not a square.
        let cornerX = Int(bubble.minX) + 2
        let cornerY = size - (Int(bubble.minY) + 2)
        let corner = pixel(output, x: cornerX, y: min(cornerY, size - 1))
        #expect(corner.r < 40, "the circle's bounding-box corner should not be camera pixels")
    }
}
