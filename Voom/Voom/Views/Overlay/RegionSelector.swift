import AppKit
import ScreenCaptureKit

@MainActor
final class RegionSelector {
    private var panel: NSPanel?
    private var selectionView: RegionSelectionView?
    private var continuation: CheckedContinuation<CGRect?, Never>?

    func selectRegion(on display: SCDisplay) async -> CGRect? {
        let screen = NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
        } ?? NSScreen.main

        guard let screen else { return nil }

        return await withCheckedContinuation { cont in
            self.continuation = cont

            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .screenSaver + 1
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false

            let view = RegionSelectionView(frame: screen.frame)
            view.onComplete = { [weak self] rect in
                self?.finish(rect: rect)
            }
            view.onCancel = { [weak self] in
                self?.finish(rect: nil)
            }
            panel.contentView = view
            self.selectionView = view
            self.panel = panel

            panel.orderFrontRegardless()
            panel.makeKey()
        }
    }

    private func finish(rect: CGRect?) {
        panel?.close()
        panel = nil
        selectionView = nil
        continuation?.resume(returning: rect)
        continuation = nil
    }
}

// MARK: - Region Selection View

final class RegionSelectionView: NSView {
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    private var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        }
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentPoint = startPoint
        isDragging = true
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint, let end = currentPoint else {
            onCancel?()
            return
        }

        let rect = CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )

        // Minimum selection size
        guard rect.width > 50 && rect.height > 50 else {
            onCancel?()
            return
        }

        // Convert from view coordinates to screen coordinates
        let screenRect = window?.convertToScreen(NSRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: rect.width,
            height: rect.height
        )) ?? rect

        onComplete?(screenRect)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Dimmed overlay
        NSColor.black.withAlphaComponent(0.3).setFill()
        dirtyRect.fill()

        guard let start = startPoint, let current = currentPoint, isDragging else {
            // Draw instruction text
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: NSColor.white
            ]
            let text = "Drag to select recording region. Press ESC to cancel."
            let size = (text as NSString).size(withAttributes: attrs)
            let point = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2)
            (text as NSString).draw(at: point, withAttributes: attrs)
            return
        }

        let selectionRect = NSRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        )

        // Clear the selection area
        NSColor.clear.setFill()
        let path = NSBezierPath(rect: selectionRect)
        path.fill()

        // White border around selection
        NSColor.white.setStroke()
        let borderPath = NSBezierPath(rect: selectionRect)
        borderPath.lineWidth = 2
        borderPath.stroke()

        // Dimension label
        let w = Int(selectionRect.width)
        let h = Int(selectionRect.height)
        let label = "\(w) × \(h)"
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.7)
        ]
        let labelSize = (label as NSString).size(withAttributes: attrs)
        let labelPoint = NSPoint(
            x: selectionRect.midX - labelSize.width / 2,
            y: selectionRect.minY - labelSize.height - 8
        )
        (label as NSString).draw(at: labelPoint, withAttributes: attrs)
    }
}
