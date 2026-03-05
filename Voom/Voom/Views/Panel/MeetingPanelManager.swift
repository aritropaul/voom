import AppKit
import SwiftUI
import VoomCore
import VoomMeetings
@preconcurrency import ScreenCaptureKit

@MainActor
final class MeetingPanelManager {
    static let shared = MeetingPanelManager()

    private var panel: NSPanel?
    private weak var currentAppState: AppState?

    func show(meeting: DetectedMeeting, appState: AppState) {
        // Force-close any stale panel
        if let old = panel {
            old.close()
            self.panel = nil
            self.currentAppState = nil
        }

        currentAppState = appState

        let panel = makePanel()

        let view = MeetingDetectedView(
            meeting: meeting,
            onRecord: { [weak self] in
                self?.dismiss()
                appState.isCameraEnabled = false
                appState.recordingMode = .fullScreen
                appState.isMeetingRecording = true
                Task { @MainActor in
                    await self?.startMeetingRecording(appState: appState)
                }
            },
            onDismiss: { [weak self] in
                self?.dismiss()
                appState.detectedMeeting = nil
            }
        )

        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = .clear
        panel.contentView = hosting

        let screen = NSScreen.main ?? NSScreen.screens[0]
        let fittingSize = hosting.fittingSize
        let size = NSSize(
            width: max(fittingSize.width, 280),
            height: max(fittingSize.height, 100)
        )
        panel.setContentSize(size)

        let visibleFrame = screen.visibleFrame
        let x = visibleFrame.maxX - size.width - 16
        let y = visibleFrame.maxY - size.height - 16
        panel.setFrameOrigin(NSPoint(x: x, y: y))

        panel.alphaValue = 1.0
        panel.orderFrontRegardless()

        self.panel = panel

        // Play chime
        NSSound(named: "Glass")?.play()
    }

    func dismiss() {
        guard let panel else { return }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                self?.panel?.close()
                self?.panel = nil
                self?.currentAppState = nil
            }
        })
    }

    // MARK: - Meeting Recording

    private func startMeetingRecording(appState: AppState) async {
        // Load displays
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            appState.availableDisplays = content.displays
        } catch { return }

        // Use interactive display picker (same as control panel)
        if let picked = await DisplayPicker.shared.pick(from: appState.availableDisplays) {
            appState.selectedDisplay = picked
        } else {
            return // user pressed ESC
        }

        // Show control panel and start recording — skip countdown
        ControlPanelManager.shared.show(appState: appState)
        NotificationCenter.default.post(name: .startRecordingFromMeeting, object: nil)
    }

    // MARK: - Private

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
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.appearance = NSAppearance(named: .darkAqua)
        return panel
    }
}
