import Foundation
import SwiftUI

enum AnnotationTool: String, CaseIterable {
    case freehand
    case arrow
    case rectangle
    case circle
    case text
}

struct AnnotationShape: Identifiable {
    let id = UUID()
    var tool: AnnotationTool
    var points: [CGPoint]
    var color: Color
    var lineWidth: CGFloat
    var text: String?
}
