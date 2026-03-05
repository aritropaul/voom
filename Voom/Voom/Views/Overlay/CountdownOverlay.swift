import AppKit
import SwiftUI
import ScreenCaptureKit
import VoomCore

// MARK: - Countdown View

struct CountdownView: View {
    let count: Int
    let progress: Double  // 0.0 → 1.0, driven by timer for smooth fill

    var body: some View {
        ZStack {
            Color.black.opacity(0.4)

            VStack(spacing: 24) {
                ZStack {
                    // Background ring track
                    Circle()
                        .stroke(.white.opacity(0.12), lineWidth: 4)
                        .frame(width: 180, height: 180)

                    // Smooth progress ring
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            .white.opacity(0.5),
                            style: StrokeStyle(lineWidth: 4, lineCap: .round)
                        )
                        .frame(width: 180, height: 180)
                        .rotationEffect(.degrees(-90))

                    // Number
                    Text("\(count)")
                        .font(.system(size: 140, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 20)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(.snappy(duration: 0.3), value: count)
                }

                Text("Recording starts in...")
                    .font(.system(.title3, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Countdown Overlay Manager

@MainActor
final class CountdownOverlay {
    static let shared = CountdownOverlay()
    private var panel: NSPanel?

    func run(display: SCDisplay?) async {
        let screen = screenFor(display: display) ?? NSScreen.main ?? NSScreen.screens[0]
        let frame = screen.frame

        let panel = NSPanel(
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
        panel.ignoresMouseEvents = true

        let blurView = NSVisualEffectView(frame: NSRect(origin: .zero, size: frame.size))
        blurView.blendingMode = .behindWindow
        blurView.material = .fullScreenUI
        blurView.state = .active
        blurView.alphaValue = 0.85

        let countdownView = CountdownHostView(frame: NSRect(origin: .zero, size: frame.size))
        countdownView.count = 3
        countdownView.progress = 0

        let container = NSView(frame: NSRect(origin: .zero, size: frame.size))
        container.addSubview(blurView)
        container.addSubview(countdownView)
        panel.contentView = container

        panel.setFrame(frame, display: true)

        // Fade in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        self.panel = panel

        nonisolated(unsafe) let panelRef = panel
        await NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panelRef.animator().alphaValue = 1.0
        })

        // Start smooth progress timer — fills from 0→1 over 3 seconds at 60fps
        let startTime = CACurrentMediaTime()
        let totalDuration: Double = 3.0
        let progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            let elapsed = CACurrentMediaTime() - startTime
            let p = min(elapsed / totalDuration, 1.0)
            Task { @MainActor in
                countdownView.progress = p
            }
        }

        // Countdown: 3, 2, 1
        for i in (1...3).reversed() {
            countdownView.count = i
            playTick()
            try? await Task.sleep(for: .seconds(1))
        }

        // Stop the progress timer
        progressTimer.invalidate()
        countdownView.progress = 1.0

        playGo()

        // Fade out
        await NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        })

        panel.close()
        self.panel = nil
    }

    private func screenFor(display: SCDisplay?) -> NSScreen? {
        guard let display else { return NSScreen.main }
        return NSScreen.screens.first {
            $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == CGDirectDisplayID(display.displayID)
        } ?? NSScreen.main
    }

    private func playTick() {
        if let sound = NSSound(named: "Tink") {
            sound.play()
        }
    }

    private func playGo() {
        if let sound = NSSound(named: "Hero") {
            sound.play()
        }
    }
}

// MARK: - Countdown Host View (NSHostingView wrapper for live updates)

final class CountdownHostView: NSView {
    private var hostingView: NSHostingView<CountdownView>?

    var count: Int = 3 {
        didSet { updateView() }
    }

    var progress: Double = 0 {
        didSet { updateView() }
    }

    private func updateView() {
        hostingView?.rootView = CountdownView(count: count, progress: progress)
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let view = CountdownView(count: 3, progress: 0)
        let hosting = NSHostingView(rootView: view)
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        self.hostingView = hosting
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
