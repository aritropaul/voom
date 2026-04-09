import Foundation

public struct ZoomKeyframe: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: TimeInterval
    public let centerX: Double
    public let centerY: Double
    public let scale: Double  // 1.0 to 3.0

    public init(timestamp: TimeInterval, centerX: Double, centerY: Double, scale: Double) {
        self.id = UUID()
        self.timestamp = timestamp
        self.centerX = centerX
        self.centerY = centerY
        self.scale = max(1.0, min(3.0, scale))
    }
}

public actor AutoZoomAnalyzer {
    public static let shared = AutoZoomAnalyzer()
    private init() {}

    /// Analyze cursor events to generate zoom keyframes
    /// Strategy: cluster click events by proximity and time, zoom in at clusters, zoom out between them
    public func analyzeForZoom(
        events: [CursorEvent],
        videoWidth: Double,
        videoHeight: Double,
        zoomScale: Double = 2.0,
        clusterTimeThreshold: TimeInterval = 2.0,
        clusterDistanceThreshold: Double = 200.0
    ) -> [ZoomKeyframe] {
        // Filter to click events only
        let clicks = events.filter { $0.eventType == .leftClick || $0.eventType == .rightClick }
        guard clicks.count >= 2 else { return [] }

        // Cluster clicks by time and spatial proximity
        var clusters: [[CursorEvent]] = []
        var currentCluster: [CursorEvent] = [clicks[0]]

        for click in clicks.dropFirst() {
            let lastInCluster = currentCluster.last!
            let timeDiff = click.timestamp - lastInCluster.timestamp
            let dist = hypot(click.x - lastInCluster.x, click.y - lastInCluster.y)

            if timeDiff < clusterTimeThreshold && dist < clusterDistanceThreshold {
                currentCluster.append(click)
            } else {
                if currentCluster.count >= 2 {
                    clusters.append(currentCluster)
                }
                currentCluster = [click]
            }
        }
        if currentCluster.count >= 2 {
            clusters.append(currentCluster)
        }

        // Generate keyframes: zoom in at cluster start, zoom out at cluster end
        var keyframes: [ZoomKeyframe] = []

        for cluster in clusters {
            let avgX = cluster.map(\.x).reduce(0, +) / Double(cluster.count)
            let avgY = cluster.map(\.y).reduce(0, +) / Double(cluster.count)
            let normalizedX = avgX / videoWidth
            let normalizedY = avgY / videoHeight
            let startTime = cluster.first!.timestamp
            let endTime = cluster.last!.timestamp + 0.5  // hold for 0.5s after last click

            // Zoom in
            keyframes.append(ZoomKeyframe(
                timestamp: max(0, startTime - 0.3),  // start zooming 0.3s before
                centerX: normalizedX,
                centerY: normalizedY,
                scale: 1.0
            ))
            keyframes.append(ZoomKeyframe(
                timestamp: startTime,
                centerX: normalizedX,
                centerY: normalizedY,
                scale: zoomScale
            ))

            // Zoom out
            keyframes.append(ZoomKeyframe(
                timestamp: endTime,
                centerX: normalizedX,
                centerY: normalizedY,
                scale: zoomScale
            ))
            keyframes.append(ZoomKeyframe(
                timestamp: endTime + 0.3,
                centerX: normalizedX,
                centerY: normalizedY,
                scale: 1.0
            ))
        }

        return keyframes
    }

    /// Write keyframes to JSON sidecar
    public func writeKeyframes(_ keyframes: [ZoomKeyframe], to url: URL) throws {
        let data = try JSONEncoder().encode(keyframes)
        try data.write(to: url)
    }
}
