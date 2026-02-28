import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import ScreenCaptureKit

// MARK: - Controls Overlay View

struct RecordingOverlayView: View {
    @Environment(AppState.self) private var appState
    let onPause: () -> Void
    let onResume: () -> Void
    let onStop: () -> Void

    @State private var isPauseHovered = false
    @State private var isStopHovered = false
    @State private var isVisible = false

    private var isPaused: Bool { appState.recordingState == .paused }

    var body: some View {
        HStack(spacing: 14) {
            // Recording indicator
            HStack(spacing: 8) {
                if isPaused {
                    Circle()
                        .fill(VoomTheme.accentRed.opacity(0.4))
                        .frame(width: 10, height: 10)
                } else {
                    PhaseAnimator([false, true]) { phase in
                        Circle()
                            .fill(VoomTheme.accentRed)
                            .frame(width: 10, height: 10)
                            .opacity(phase ? 0.3 : 1.0)
                    } animation: { _ in
                        .easeInOut(duration: 1.2)
                    }
                }

                Text(isPaused ? "Paused" : "Recording")
                    .font(.system(.caption, weight: .medium))
                    .foregroundStyle(isPaused ? Color.secondary : Color.white)
                    .contentTransition(.interpolate)
                    .animation(.smooth(duration: 0.2), value: isPaused)
            }

            // Timer
            Text(appState.formattedDuration)
                .font(.system(.title3, design: .monospaced, weight: .medium))
                .foregroundStyle(.white)
                .monospacedDigit()
                .contentTransition(.numericText(countsDown: false))
                .animation(.snappy(duration: 0.25), value: appState.formattedDuration)

            Divider()
                .frame(height: 20)
                .overlay(VoomTheme.borderMedium)

            // Pause/Resume
            Button {
                if isPaused { onResume() } else { onPause() }
            } label: {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(isPauseHovered ? VoomTheme.backgroundSelected : VoomTheme.backgroundHover.opacity(2.5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(isPauseHovered ? 1.05 : 1.0)
            .animation(.smooth(duration: 0.12), value: isPauseHovered)
            .onHover { isPauseHovered = $0 }

            // Stop
            Button {
                onStop()
            } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(VoomTheme.accentRed.opacity(isStopHovered ? 0.85 : 0.65))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .scaleEffect(isStopHovered ? 1.05 : 1.0)
            .animation(.smooth(duration: 0.12), value: isStopHovered)
            .onHover { isStopHovered = $0 }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .background(.black.opacity(0.45))
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
        )
        // Sleeve-style layered shadows
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .shadow(color: .black.opacity(0.08), radius: 1, y: 0)
        .scaleEffect(isVisible ? 1.0 : 0.92)
        .opacity(isVisible ? 1.0 : 0)
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.78)) {
                isVisible = true
            }
        }
    }
}

// MARK: - Camera PiP NSView

final class CameraPiPNSView: NSView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, size: CGFloat, cornerRadius: CGFloat) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: NSRect(x: 0, y: 0, width: size, height: size))
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.cornerRadius = cornerRadius
        previewLayer.masksToBounds = true
        previewLayer.transform = CATransform3DMakeScale(-1, 1, 1)
        wantsLayer = true
        layer = CALayer()
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

// MARK: - Overlay Manager

@MainActor
final class OverlayManager {
    static let shared = OverlayManager()
    private var cameraPanel: NSPanel?
    private var currentPipPosition: PiPPosition = .bottomRight
    private var currentScreen: NSScreen?

    // MARK: - Camera PiP

    /// Show camera PiP overlay using an externally-managed session.
    /// The caller owns the session lifecycle — OverlayManager only displays it.
    func showCameraPiP(session: AVCaptureSession, display: SCDisplay?, pipPosition: PiPPosition) {
        let targetScreen = screenFor(display: display) ?? NSScreen.main
        // If already showing on the correct screen, skip
        if cameraPanel != nil && currentScreen == targetScreen { return }
        // If showing on wrong screen, tear down and recreate
        if cameraPanel != nil { hideCameraPiPImmediate() }

        currentPipPosition = pipPosition
        currentScreen = targetScreen

        let size: CGFloat = 240
        let margin: CGFloat = 32
        let cornerRadius: CGFloat = size / 2
        let borderWidth: CGFloat = 1.5
        let outerPad: CGFloat = 40 // generous room for layered shadows
        let totalSize = size + (outerPad * 2)

        let panel = makePanel(contentRect: NSRect(x: 0, y: 0, width: totalSize, height: totalSize))
        panel.hasShadow = false

        // Outer container
        let outerContainer = NSView(frame: NSRect(x: 0, y: 0, width: totalSize, height: totalSize))
        outerContainer.wantsLayer = true
        outerContainer.layer = CALayer()

        // Large soft ambient shadow
        let ambientShadow = CALayer()
        ambientShadow.frame = CGRect(x: outerPad, y: outerPad, width: size, height: size)
        ambientShadow.cornerRadius = cornerRadius
        ambientShadow.backgroundColor = NSColor.black.withAlphaComponent(0.25).cgColor
        ambientShadow.shadowColor = NSColor.black.cgColor
        ambientShadow.shadowOpacity = 0.6
        ambientShadow.shadowRadius = 28
        ambientShadow.shadowOffset = CGSize(width: 0, height: -6)
        ambientShadow.masksToBounds = false
        outerContainer.layer?.addSublayer(ambientShadow)

        // Mid-range shadow for depth
        let midShadow = CALayer()
        midShadow.frame = CGRect(x: outerPad, y: outerPad, width: size, height: size)
        midShadow.cornerRadius = cornerRadius
        midShadow.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        midShadow.shadowColor = NSColor.black.cgColor
        midShadow.shadowOpacity = 0.35
        midShadow.shadowRadius = 10
        midShadow.shadowOffset = CGSize(width: 0, height: -3)
        midShadow.masksToBounds = false
        outerContainer.layer?.addSublayer(midShadow)

        // Tight contact shadow for definition
        let contactShadow = CALayer()
        contactShadow.frame = CGRect(x: outerPad, y: outerPad, width: size, height: size)
        contactShadow.cornerRadius = cornerRadius
        contactShadow.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        contactShadow.shadowColor = NSColor.black.cgColor
        contactShadow.shadowOpacity = 0.25
        contactShadow.shadowRadius = 2
        contactShadow.shadowOffset = CGSize(width: 0, height: -1)
        contactShadow.masksToBounds = false
        outerContainer.layer?.addSublayer(contactShadow)

        // Camera content
        let pipView = CameraPiPNSView(session: session, size: size, cornerRadius: cornerRadius)
        pipView.frame = NSRect(x: outerPad, y: outerPad, width: size, height: size)

        // Clip container for camera feed
        let clipContainer = NSView(frame: NSRect(x: outerPad, y: outerPad, width: size, height: size))
        clipContainer.wantsLayer = true
        clipContainer.layer = CALayer()
        clipContainer.layer?.cornerRadius = cornerRadius
        clipContainer.layer?.masksToBounds = true
        clipContainer.addSubview(pipView)
        pipView.frame = clipContainer.bounds

        outerContainer.addSubview(clipContainer)

        // Border ring — subtle white glow
        let borderLayer = CAShapeLayer()
        let borderRect = CGRect(x: outerPad, y: outerPad, width: size, height: size)
        borderLayer.path = NSBezierPath(roundedRect: borderRect, xRadius: cornerRadius, yRadius: cornerRadius).cgPath
        borderLayer.fillColor = nil
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.15).cgColor
        borderLayer.lineWidth = borderWidth
        outerContainer.layer?.addSublayer(borderLayer)

        panel.contentView = outerContainer

        if let screen = currentScreen {
            // Position accounts for outer padding
            let baseOrigin = cameraPiPOrigin(screen: screen, size: size, margin: margin, position: pipPosition)
            let adjustedOrigin = NSPoint(x: baseOrigin.x - outerPad, y: baseOrigin.y - outerPad)
            panel.setFrameOrigin(adjustedOrigin)
        }

        // Smooth fade-in
        panel.alphaValue = 0
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        })

        self.cameraPanel = panel
    }

    func hideCameraPiP() {
        guard let panel = cameraPanel else { return }
        cameraPanel = nil
        currentScreen = nil

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: {
            DispatchQueue.main.async {
                panel.close()
            }
        })
    }

    /// Tear down the camera panel immediately without animation.
    func hideCameraPiPImmediate() {
        guard let panel = cameraPanel else { return }
        cameraPanel = nil
        currentScreen = nil
        panel.close()
    }

    var isCameraShowing: Bool { cameraPanel != nil }

    /// The window number of the camera PiP panel, used to include it in screen capture.
    var cameraPanelWindowNumber: Int? { cameraPanel?.windowNumber }

    /// Animate the camera PiP to a new corner position without tearing it down.
    func moveCameraPiP(to position: PiPPosition) {
        guard let panel = cameraPanel, let screen = currentScreen else { return }
        currentPipPosition = position
        let size: CGFloat = 240
        let margin: CGFloat = 32
        let outerPad: CGFloat = 40
        let baseOrigin = cameraPiPOrigin(screen: screen, size: size, margin: margin, position: position)
        let adjustedOrigin = NSPoint(x: baseOrigin.x - outerPad, y: baseOrigin.y - outerPad)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrameOrigin(adjustedOrigin)
        }
    }

    // MARK: - Helpers

    private func screenFor(display: SCDisplay?) -> NSScreen? {
        guard let display else { return NSScreen.main }
        return NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
        } ?? NSScreen.main
    }

    private func makePanel(contentRect: NSRect) -> NSPanel {
        let panel = NSPanel(
            contentRect: contentRect,
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
        return panel
    }

    private func cameraPiPOrigin(screen: NSScreen, size: CGFloat, margin: CGFloat, position: PiPPosition) -> NSPoint {
        switch position {
        case .bottomLeft:
            return NSPoint(x: screen.frame.minX + margin, y: screen.frame.minY + margin)
        case .bottomRight:
            return NSPoint(x: screen.frame.maxX - size - margin, y: screen.frame.minY + margin)
        case .topLeft:
            return NSPoint(x: screen.frame.minX + margin, y: screen.frame.maxY - size - margin)
        case .topRight:
            return NSPoint(x: screen.frame.maxX - size - margin, y: screen.frame.maxY - size - margin)
        }
    }
}

// MARK: - NSBezierPath CGPath Extension

private extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var points = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            let type = element(at: i, associatedPoints: &points)
            switch type {
            case .moveTo:
                path.move(to: points[0])
            case .lineTo:
                path.addLine(to: points[0])
            case .curveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .closePath:
                path.closeSubpath()
            case .cubicCurveTo:
                path.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo:
                path.addQuadCurve(to: points[1], control: points[0])
            @unknown default:
                break
            }
        }
        return path
    }
}
