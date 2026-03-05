import AppKit
import SwiftUI
import VoomCore
@preconcurrency import ScreenCaptureKit

@MainActor
final class ControlPanelManager {
    static let shared = ControlPanelManager()

    private var panel: NSPanel?
    private var hostingView: NSHostingView<AnyView>?
    private weak var currentAppState: AppState?

    func toggle(appState: AppState) {
        if panel != nil {
            hide(appState: appState)
        } else {
            show(appState: appState)
        }
    }

    func show(appState: AppState) {
        if let existing = panel {
            existing.orderFrontRegardless()
            appState.isPanelVisible = true
            return
        }

        currentAppState = appState

        let panel = makePanel()

        let view = ControlPanelView(
            onOpenLibrary: { [weak self] in
                self?.openLibrary()
            },
            onQuit: {
                NSApplication.shared.terminate(nil)
            },
            onDismiss: { [weak self] in
                guard let self, let state = self.currentAppState else { return }
                self.hide(appState: state)
            }
        )
        .environment(appState)
        .environment(RecordingStore.shared)

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        // Position on the correct screen — use the mouse screen as fallback
        let screen = screenForPanel(appState: appState)
        positionPanel(panel, on: screen)

        autoSelectDisplay(for: screen, appState: appState)

        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }

        self.panel = panel
        self.hostingView = hosting
        appState.isPanelVisible = true
    }

    func hide(appState: AppState) {
        guard let panel else { return }

        appState.isPanelVisible = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.close()
                self?.panel = nil
                self?.hostingView = nil
                self?.currentAppState = nil
            }
        })
    }

    func moveToDisplay(appState: AppState) {
        guard let panel else { return }
        let screen = screenForPanel(appState: appState)
        let origin = panelOrigin(panelSize: panel.frame.size, on: screen)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(origin)
        }
    }

    /// Re-center the panel horizontally on its current screen after content size changes.
    func recenterPanel(appState: AppState) {
        guard let panel, let hosting = panel.contentView as? NSHostingView<AnyView> else { return }
        // Use the screen the panel is currently on, NOT the selected display
        let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let fittingSize = hosting.fittingSize
        let currentFrame = panel.frame
        // Keep centered horizontally on the same screen, keep same Y
        let newX = screen.visibleFrame.midX - fittingSize.width / 2
        let newY = currentFrame.origin.y

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(
                NSRect(x: newX, y: newY, width: fittingSize.width, height: fittingSize.height),
                display: true
            )
        }
    }

    // MARK: - Private

    /// Auto-select the SCDisplay matching the given NSScreen.
    private func autoSelectDisplay(for screen: NSScreen, appState: AppState) {
        guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }
        Task {
            let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let displays = content?.displays, !displays.isEmpty else { return }
            appState.availableDisplays = displays
            appState.selectedDisplay = displays.first(where: { CGDirectDisplayID($0.displayID) == screenNumber }) ?? displays.first
        }
    }

    /// Compute the panel origin: centered horizontally, just above the dock.
    private func panelOrigin(panelSize: CGSize, on screen: NSScreen) -> NSPoint {
        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.midX - panelSize.width / 2
        let y = visibleFrame.minY
        return NSPoint(x: x, y: y)
    }

    /// Position and size the panel on a specific screen.
    private func positionPanel(_ panel: NSPanel, on screen: NSScreen) {
        if let hosting = panel.contentView as? NSHostingView<AnyView> {
            let fittingSize = hosting.fittingSize
            panel.setContentSize(fittingSize)
        }
        let origin = panelOrigin(panelSize: panel.frame.size, on: screen)
        panel.setFrameOrigin(origin)
    }

    /// Resolve the correct screen for the panel.
    /// Priority: selectedDisplay → screen containing the mouse → main screen.
    private func screenForPanel(appState: AppState) -> NSScreen {
        // 1. Match the selected SCDisplay to an NSScreen
        if let display = appState.selectedDisplay {
            if let matched = NSScreen.screens.first(where: {
                $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
            }) {
                return matched
            }
        }
        // 2. Use the screen where the mouse cursor is
        let mouseLocation = NSEvent.mouseLocation
        if let mouseScreen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) {
            return mouseScreen
        }
        // 3. Fallback
        return NSScreen.main ?? NSScreen.screens[0]
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .screenSaver
        panel.isMovableByWindowBackground = true
        panel.hasShadow = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }

    private func openLibrary() {
        NSApp.activate()
        WindowActions.openWindow?(id: "library")
    }
}
