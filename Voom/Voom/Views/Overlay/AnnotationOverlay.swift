import SwiftUI
import AppKit
import VoomCore

@MainActor
final class AnnotationPanel {
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnnotationOverlayView>?

    var windowNumber: Int? { panel?.windowNumber }

    var shapes: [AnnotationShape] {
        get { hostingView?.rootView.viewModel.shapes ?? [] }
    }

    func show(on screen: NSScreen) {
        let viewModel = AnnotationViewModel()
        let view = AnnotationOverlayView(viewModel: viewModel)
        let hosting = NSHostingView(rootView: view)

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver - 1
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.contentView = hosting

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = hosting
    }

    func hide() {
        panel?.close()
        panel = nil
        hostingView = nil
    }
}

// MARK: - View Model

@Observable
@MainActor
final class AnnotationViewModel {
    var shapes: [AnnotationShape] = []
    var currentTool: AnnotationTool = .freehand
    var currentColor: Color = .red
    var lineWidth: CGFloat = 3
    var currentPoints: [CGPoint] = []
    var isDrawing = false
    var textInput: String = ""

    func undo() {
        if !shapes.isEmpty { shapes.removeLast() }
    }

    func clear() {
        shapes.removeAll()
    }

    func finishShape() {
        guard !currentPoints.isEmpty else { return }
        let shape = AnnotationShape(
            tool: currentTool,
            points: currentPoints,
            color: currentColor,
            lineWidth: lineWidth,
            text: currentTool == .text ? textInput : nil
        )
        shapes.append(shape)
        currentPoints = []
        isDrawing = false
        textInput = ""
    }
}

// MARK: - Overlay View

struct AnnotationOverlayView: View {
    @State var viewModel: AnnotationViewModel

    private let presetColors: [Color] = [
        .red, .orange, .yellow, .green, .blue, .purple, .white, .black
    ]

    var body: some View {
        ZStack {
            // Drawing canvas
            Canvas { context, size in
                for shape in viewModel.shapes {
                    drawShape(shape, in: &context)
                }
                // Current in-progress shape
                if viewModel.isDrawing && !viewModel.currentPoints.isEmpty {
                    let inProgress = AnnotationShape(
                        tool: viewModel.currentTool,
                        points: viewModel.currentPoints,
                        color: viewModel.currentColor,
                        lineWidth: viewModel.lineWidth
                    )
                    drawShape(inProgress, in: &context)
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !viewModel.isDrawing {
                            viewModel.isDrawing = true
                            viewModel.currentPoints = [value.startLocation]
                        }
                        viewModel.currentPoints.append(value.location)
                    }
                    .onEnded { _ in
                        viewModel.finishShape()
                    }
            )

            // Toolbar
            VStack {
                AnnotationToolbar(viewModel: viewModel, presetColors: presetColors)
                    .padding(.top, 20)
                Spacer()
            }
        }
    }

    private func drawShape(_ shape: AnnotationShape, in context: inout GraphicsContext) {
        let color = shape.color

        switch shape.tool {
        case .freehand:
            guard shape.points.count >= 2 else { return }
            var path = Path()
            path.move(to: shape.points[0])
            for point in shape.points.dropFirst() {
                path.addLine(to: point)
            }
            context.stroke(path, with: .color(color), lineWidth: shape.lineWidth)

        case .arrow:
            guard shape.points.count >= 2 else { return }
            let start = shape.points.first!
            let end = shape.points.last!
            var path = Path()
            path.move(to: start)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), lineWidth: shape.lineWidth)

            // Arrowhead
            let angle = atan2(end.y - start.y, end.x - start.x)
            let headLength: CGFloat = 15
            let headAngle: CGFloat = .pi / 6
            let head1 = CGPoint(
                x: end.x - headLength * cos(angle - headAngle),
                y: end.y - headLength * sin(angle - headAngle)
            )
            let head2 = CGPoint(
                x: end.x - headLength * cos(angle + headAngle),
                y: end.y - headLength * sin(angle + headAngle)
            )
            var arrowHead = Path()
            arrowHead.move(to: head1)
            arrowHead.addLine(to: end)
            arrowHead.addLine(to: head2)
            context.stroke(arrowHead, with: .color(color), lineWidth: shape.lineWidth)

        case .rectangle:
            guard shape.points.count >= 2 else { return }
            let start = shape.points.first!
            let end = shape.points.last!
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            context.stroke(Path(rect), with: .color(color), lineWidth: shape.lineWidth)

        case .circle:
            guard shape.points.count >= 2 else { return }
            let start = shape.points.first!
            let end = shape.points.last!
            let rect = CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: shape.lineWidth)

        case .text:
            guard let text = shape.text, let point = shape.points.first else { return }
            context.draw(
                Text(text).foregroundStyle(color).font(.system(size: 18, weight: .medium)),
                at: point
            )
        }
    }
}
