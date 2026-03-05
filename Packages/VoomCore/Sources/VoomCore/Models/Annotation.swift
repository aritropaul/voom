import Foundation
import SwiftUI

public enum AnnotationTool: String, CaseIterable, Sendable {
    case freehand
    case arrow
    case rectangle
    case circle
    case text
}

public struct AnnotationShape: Identifiable, Sendable {
    public let id = UUID()
    public var tool: AnnotationTool
    public var points: [CGPoint]
    public var color: Color
    public var lineWidth: CGFloat
    public var text: String?

    public init(tool: AnnotationTool, points: [CGPoint], color: Color, lineWidth: CGFloat, text: String? = nil) {
        self.tool = tool
        self.points = points
        self.color = color
        self.lineWidth = lineWidth
        self.text = text
    }
}
