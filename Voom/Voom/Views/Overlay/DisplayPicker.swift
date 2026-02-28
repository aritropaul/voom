import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit

// MARK: - Display Picker View

struct DisplayPickerView: View {
    let displayNumber: Int
    let isHighlighted: Bool

    var body: some View {
        ZStack {
            // Base dim
            Color.black.opacity(isHighlighted ? 0.15 : 0.55)

            // Radial gradient spotlight when highlighted
            if isHighlighted {
                RadialGradient(
                    colors: [
                        .black.opacity(0.65),
                        .black.opacity(0.25),
                        .black.opacity(0.10)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 400
                )

                // Content
                VStack(spacing: 16) {
                    Image(systemName: "display")
                        .font(.system(size: 64, weight: .thin))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 12)
                    Text("Display \(displayNumber)")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.6), radius: 8)
                    Text("Click to record this display")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.8))
                        .shadow(color: .black.opacity(0.5), radius: 6)
                    Text("Press ESC to cancel")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.5))
                        .shadow(color: .black.opacity(0.4), radius: 4)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: isHighlighted)
        .ignoresSafeArea()
    }
}

// MARK: - Display Picker Host View

final class DisplayPickerHostView: NSView {
    private var hostingView: NSHostingView<DisplayPickerView>?
    private var blurView: NSVisualEffectView?
    private let displayNumber: Int

    var isHighlighted: Bool = false {
        didSet {
            updateView()
            updateBlur()
        }
    }

    init(frame: NSRect, displayNumber: Int) {
        self.displayNumber = displayNumber
        super.init(frame: frame)

        // Background blur layer
        let blur = NSVisualEffectView(frame: bounds)
        blur.blendingMode = .behindWindow
        blur.material = .fullScreenUI
        blur.state = .active
        blur.alphaValue = 0
        blur.autoresizingMask = [.width, .height]
        addSubview(blur)
        self.blurView = blur

        // SwiftUI content on top
        let view = DisplayPickerView(displayNumber: displayNumber, isHighlighted: false)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hostingView = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateView() {
        hostingView?.rootView = DisplayPickerView(displayNumber: displayNumber, isHighlighted: isHighlighted)
    }

    private func updateBlur() {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            blurView?.animator().alphaValue = isHighlighted ? 0.7 : 0
        }
    }
}

// MARK: - Key-Capable Panel

private class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

// MARK: - Display Picker

@MainActor
final class DisplayPicker {
    static let shared = DisplayPicker()

    private var panels: [(panel: NSPanel, display: SCDisplay, hostView: DisplayPickerHostView)] = []
    private var globalMoveMonitor: Any?
    private var localMoveMonitor: Any?
    private var mouseClickMonitor: Any?
    private var keyMonitor: Any?
    private var continuation: CheckedContinuation<SCDisplay?, Never>?

    func pick(from displays: [SCDisplay]) async -> SCDisplay? {
        // Single display — return immediately, no UI
        if displays.count <= 1 {
            return displays.first
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            showOverlays(for: displays)
        }
    }

    // MARK: - Private

    private func showOverlays(for displays: [SCDisplay]) {
        for (index, display) in displays.enumerated() {
            guard let screen = screenFor(display: display) else { continue }
            let frame = screen.frame

            let panel = KeyablePanel(
                contentRect: frame,
                styleMask: [.nonactivatingPanel, .borderless],
                backing: .buffered,
                defer: false
            )
            panel.isFloatingPanel = true
            panel.level = .screenSaver
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.hidesOnDeactivate = false
            panel.ignoresMouseEvents = false
            panel.acceptsMouseMovedEvents = true

            let hostView = DisplayPickerHostView(
                frame: NSRect(origin: .zero, size: frame.size),
                displayNumber: index + 1
            )
            panel.contentView = hostView
            panel.setFrame(frame, display: true)

            // Fade in
            panel.alphaValue = 0
            panel.orderFrontRegardless()

            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1.0
            }

            panels.append((panel: panel, display: display, hostView: hostView))
        }

        // Activate the app and make a panel key so local key events (ESC) are received
        NSApp.activate(ignoringOtherApps: true)
        panels.first?.panel.makeKeyAndOrderFront(nil)

        installMonitors()
        handleMouseMoved()
    }

    private func installMonitors() {
        // Mouse move — need BOTH local (events on our panels) and global (events on other apps)
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
            return event
        }
        globalMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            Task { @MainActor in
                self?.handleMouseMoved()
            }
        }

        // Click — select display
        mouseClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            Task { @MainActor in
                self?.handleClick(event: event)
            }
            return nil // consume the event
        }

        // ESC key — cancel (local monitor consumes the event so it doesn't leak to other apps)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // ESC
                Task { @MainActor in
                    self?.finish(selected: nil)
                }
                return nil // consume the event
            }
            return event
        }
    }

    private func handleMouseMoved() {
        let mouseLocation = NSEvent.mouseLocation
        for entry in panels {
            let isOnThisScreen = entry.panel.frame.contains(mouseLocation)
            entry.hostView.isHighlighted = isOnThisScreen
        }
    }

    private func handleClick(event: NSEvent) {
        // Find which panel was clicked
        for entry in panels {
            if entry.panel == event.window {
                finish(selected: entry.display)
                return
            }
        }
        // Click outside any panel — cancel
        finish(selected: nil)
    }

    private func finish(selected: SCDisplay?) {
        guard let continuation else { return }
        self.continuation = nil

        // Remove monitors
        if let monitor = globalMoveMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localMoveMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = mouseClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        globalMoveMonitor = nil
        localMoveMonitor = nil
        mouseClickMonitor = nil
        keyMonitor = nil

        // Fade out all panels
        let panelsToClose = panels
        panels = []

        nonisolated(unsafe) let panelsToFade = panelsToClose
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for entry in panelsToFade {
                entry.panel.animator().alphaValue = 0
            }
        }, completionHandler: {
            DispatchQueue.main.async {
                for entry in panelsToFade {
                    entry.panel.close()
                }
            }
        })

        nonisolated(unsafe) let result = selected
        continuation.resume(returning: result)
    }

    private func screenFor(display: SCDisplay) -> NSScreen? {
        NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
        }
    }
}
