import AppKit
import VoomCore
@preconcurrency import ScreenCaptureKit

// MARK: - Window Picker Host View

/// Dims its whole screen, then punches the hovered window's rect back out so the
/// user sees the real window at full brightness — the same read as the system
/// screenshot tool's window mode.
final class WindowPickerHostView: NSView {
    /// Hovered window rect in AppKit screen coordinates, or nil when nothing is
    /// under the pointer on any screen.
    var highlight: CGRect? {
        didSet {
            guard highlight != oldValue else { return }
            needsDisplay = true
        }
    }

    /// Label for the hovered window. Only the screen holding the window's centre
    /// draws it, so a window spanning two displays doesn't get two captions.
    var caption: String? {
        didSet {
            guard caption != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.55)
        let localHighlight = highlight.map { convert($0, from: nil) }

        // Even-odd winding leaves the highlighted rect undimmed instead of
        // painting over it — filling with .clear would be a no-op under the
        // default source-over compositing.
        let path = NSBezierPath(rect: bounds)
        if let localHighlight, !localHighlight.isEmpty {
            path.append(NSBezierPath(rect: localHighlight))
            path.windingRule = .evenOdd
        }
        dim.setFill()
        path.fill()

        guard let localHighlight, !localHighlight.isEmpty else {
            drawHint()
            return
        }

        NSColor.white.withAlphaComponent(0.9).setStroke()
        let border = NSBezierPath(rect: localHighlight.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()

        if let caption {
            drawCaption(caption, over: localHighlight)
        }
    }

    private func drawHint() {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 18, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.85)
        ]
        let text = "Hover a window to record it. Press ESC to cancel."
        let size = (text as NSString).size(withAttributes: attrs)
        let point = NSPoint(x: (bounds.width - size.width) / 2, y: bounds.height / 2)
        (text as NSString).draw(at: point, withAttributes: attrs)
    }

    private func drawCaption(_ caption: String, over rect: CGRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let textSize = (caption as NSString).size(withAttributes: attrs)
        let padding: CGFloat = 10
        let chipSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding)

        // Prefer just below the window; flip inside when that would fall off screen.
        var chipOrigin = NSPoint(
            x: rect.midX - chipSize.width / 2,
            y: rect.minY - chipSize.height - 8
        )
        if chipOrigin.y < bounds.minY + 8 {
            chipOrigin.y = rect.minY + 8
        }
        chipOrigin.x = min(max(chipOrigin.x, bounds.minX + 8), bounds.maxX - chipSize.width - 8)

        let chip = NSRect(origin: chipOrigin, size: chipSize)
        NSColor.black.withAlphaComponent(0.8).setFill()
        NSBezierPath(roundedRect: chip, xRadius: 6, yRadius: 6).fill()
        (caption as NSString).draw(
            at: NSPoint(x: chip.minX + padding, y: chip.minY + padding / 2),
            withAttributes: attrs
        )
    }
}

// MARK: - Window Picker

/// Full-screen hover picker for a single window, mirroring `DisplayPicker`'s
/// panel-per-screen lifecycle: click to select, ESC or a click on empty desktop
/// to cancel.
@MainActor
final class WindowPicker {
    static let shared = WindowPicker()

    private var panels: [(panel: NSPanel, screen: NSScreen, hostView: WindowPickerHostView)] = []
    private var windows: [CapturableWindow] = []
    private var hovered: CapturableWindow?
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var mouseClickMonitor: Any?
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<CapturableWindow?, Never>?

    /// Presents the picker. Returns nil when the user cancels or no window
    /// qualifies. `windows` must be front-to-back so hit-testing picks the
    /// topmost window under the pointer.
    func pick(from windows: [CapturableWindow]) async -> CapturableWindow? {
        guard !windows.isEmpty else { return nil }
        // A picker already on screen would double-install event monitors.
        guard continuation == nil else { return nil }

        self.windows = windows
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showOverlays()
        }
    }

    // MARK: - Private

    private func showOverlays() {
        for screen in NSScreen.screens {
            let frame = screen.frame
            let panel = NSPanel(
                contentRect: frame,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            // Above the control panel and camera PiP, matching RegionSelector:
            // the picker runs before capture starts and must own the screen.
            panel.level = .screenSaver + 1
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let hostView = WindowPickerHostView(frame: NSRect(origin: .zero, size: frame.size))
            panel.contentView = hostView
            panel.setFrame(frame, display: true)

            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }

            panels.append((panel: panel, screen: screen, hostView: hostView))
        }

        // Nonactivating panels don't become key on their own, and without a key
        // window the local keyDown monitor never sees ESC.
        NSApp.activate()
        panels.first?.panel.makeKeyAndOrderFront(nil)

        installMonitors()
        handleMouseMoved()
    }

    private func installMonitors() {
        // Local covers the pointer over our own panels, global covers it over
        // other apps' windows — both are needed to keep the highlight in sync.
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in self?.handleMouseMoved() }
            return event
        }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in self?.handleMouseMoved() }
        }
        mouseClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            Task { @MainActor in self?.handleClick() }
            return nil // consume so the click never reaches the window below
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                Task { @MainActor in self?.finish(selected: nil) }
                return nil // consume so ESC doesn't leak to other apps
            }
            return event
        }
    }

    private func handleMouseMoved() {
        guard !panels.isEmpty, let primaryMaxY = NSScreen.screens.first?.frame.maxY else { return }
        let cgPoint = WindowCatalog.coreGraphicsPoint(
            fromAppKit: NSEvent.mouseLocation,
            primaryScreenMaxY: primaryMaxY
        )
        let window = WindowCatalog.topmostWindow(at: cgPoint, in: windows)
        guard window != hovered else { return }
        hovered = window

        let appKitRect = window.map {
            WindowCatalog.appKitRect(fromCoreGraphics: $0.frame, primaryScreenMaxY: primaryMaxY)
        }
        for entry in panels {
            entry.hostView.highlight = appKitRect
            // Only the screen containing the window's centre captions it.
            let ownsCaption = appKitRect.map { entry.screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
            entry.hostView.caption = ownsCaption ? window?.displayLabel : nil
        }
    }

    private func handleClick() {
        finish(selected: hovered)
    }

    private func finish(selected: CapturableWindow?) {
        guard let continuation else { return }
        self.continuation = nil

        for monitor in [globalMoveMonitor, localMoveMonitor, mouseClickMonitor, keyMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        mouseClickMonitor = nil
        keyMonitor = nil

        let panelsToClose = panels
        panels = []
        windows = []
        hovered = nil

        nonisolated(unsafe) let panelsToFade = panelsToClose
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for entry in panelsToFade {
                entry.panel.animator().alphaValue = 0
            }
        }, completionHandler: {
            Task { @MainActor in
                for entry in panelsToFade {
                    entry.panel.close()
                }
            }
        })

        continuation.resume(returning: selected)
    }
}
