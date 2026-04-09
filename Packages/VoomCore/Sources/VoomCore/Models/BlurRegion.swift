import Foundation
import CoreGraphics

public struct BlurRegion: Codable, Identifiable, Sendable, Hashable {
    public var id: UUID
    public var rect: NormalizedRect  // 0-1 normalized coordinates
    public var startTime: TimeInterval?  // nil = entire video
    public var endTime: TimeInterval?

    public init(rect: NormalizedRect, startTime: TimeInterval? = nil, endTime: TimeInterval? = nil) {
        self.id = UUID()
        self.rect = rect
        self.startTime = startTime
        self.endTime = endTime
    }

    public func isActive(at time: TimeInterval) -> Bool {
        if let start = startTime, time < start { return false }
        if let end = endTime, time > end { return false }
        return true
    }
}

public struct NormalizedRect: Codable, Sendable, Hashable {
    public var x: Double  // 0-1
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = max(0, min(1, x))
        self.y = max(0, min(1, y))
        self.width = max(0, min(1, width))
        self.height = max(0, min(1, height))
    }

    public func toCGRect(in size: CGSize) -> CGRect {
        CGRect(
            x: x * size.width,
            y: y * size.height,
            width: width * size.width,
            height: height * size.height
        )
    }
}
