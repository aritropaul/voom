import SwiftUI
import ScreenCaptureKit

struct ControlPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var screenRecorder: ScreenRecorder?
    @State private var activeCamera: CameraCapture?
    @State private var durationTimer: Timer?
    @State private var hasScreenPermission = CGPreflightScreenCaptureAccess()
    @State private var errorMessage: String?
    @State private var isRecordHovered = false

    let onOpenLibrary: () -> Void
    let onQuit: () -> Void
    let onDismiss: () -> Void

    private var isRecordingActive: Bool {
        appState.recordingState == .recording || appState.recordingState == .paused
    }

    var body: some View {
        barContent
            .padding(.horizontal, 6)
            .padding(.vertical, 6)
            .background(VoomTheme.backgroundPrimary)
            .clipShape(Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(VoomTheme.borderMedium, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 20, y: 8)
            .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            .padding(40)
            .fixedSize()
            .preferredColorScheme(.dark)
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: isRecordingActive)
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: appState.isCameraEnabled)
            .onAppear {
                hasScreenPermission = CGPreflightScreenCaptureAccess()
                if appState.recordingState == .idle && appState.isCameraEnabled {
                    Task { await startCameraPreview() }
                }
            }
            .onDisappear {
                stopCameraPreview()
            }
            .onChange(of: appState.isCameraEnabled) { _, enabled in
                if appState.recordingState != .idle { return }
                if enabled {
                    Task { await startCameraPreview() }
                } else {
                    stopCameraPreview()
                }
            }
            .onChange(of: appState.pipPosition) { _, newPosition in
                guard appState.isCameraEnabled, OverlayManager.shared.isCameraShowing else { return }
                OverlayManager.shared.moveCameraPiP(to: newPosition)
            }
            .onChange(of: appState.recordingState) { oldValue, newValue in
                let wasRecording = oldValue == .recording || oldValue == .paused
                let isNowRecording = newValue == .recording || newValue == .paused
                if wasRecording != isNowRecording {
                    if let delegate = NSApp.delegate as? AppDelegate {
                        delegate.updateStatusIcon(recording: isNowRecording)
                    }
                    // Re-center panel after morph completes
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        ControlPanelManager.shared.recenterPanel(appState: appState)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopRecordingFromMenuBar)) { _ in
                if isRecordingActive {
                    Task { await stopRecording() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRecordingFromHotkey)) { _ in
                if isRecordingActive {
                    Task { await stopRecording() }
                } else if appState.canStartRecording {
                    Task { await startRecording() }
                }
            }
    }

    // MARK: - Bar Content

    @ViewBuilder
    private var barContent: some View {
        HStack(spacing: 0) {
            if isRecordingActive {
                recordingContent
            } else {
                idleContent
            }
        }
    }

    // MARK: - Idle Content

    @ViewBuilder
    private var idleContent: some View {
        // Dismiss button
        iconButton(icon: "xmark", dimmed: true) {
            stopCameraPreview()
            onDismiss()
        }

        // Open library
        iconButton(icon: "square.grid.2x2", dimmed: true) {
            onOpenLibrary()
        }

        divider

        // Toggle buttons
        HStack(spacing: 2) {
            toggleButton(icon: "camera.fill", isOn: appState.isCameraEnabled) {
                appState.isCameraEnabled.toggle()
            }
            toggleButton(icon: "mic.fill", isOn: appState.isMicEnabled) {
                appState.isMicEnabled.toggle()
            }
            toggleButton(icon: "speaker.wave.2.fill", isOn: appState.isSystemAudioEnabled) {
                appState.isSystemAudioEnabled.toggle()
            }
        }

        divider

        // PiP position (only if camera on)
        if appState.isCameraEnabled {
            Menu {
                ForEach(PiPPosition.allCases, id: \.self) { pos in
                    Button(pos.label) { appState.pipPosition = pos }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "pip")
                        .font(.system(size: 11))
                    Text(appState.pipPosition.label)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(VoomTheme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(VoomTheme.backgroundHover)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            divider
        }

        // Display selector
        Button {
            Task { await pickDisplay() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "display")
                    .font(.system(size: 11))
                Text(displayLabel)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(VoomTheme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(VoomTheme.backgroundHover)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(VoomTheme.borderSubtle, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)

        divider

        // Record button
        Button {
            Task { await startRecording() }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(Color.white)
                    .frame(width: 7, height: 7)
                Text("Record")
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(VoomTheme.accentRed)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .shadow(color: VoomTheme.accentRed.opacity(0.3), radius: 8)
        .opacity(isRecordHovered ? 0.85 : 1.0)
        .animation(.easeOut(duration: 0.1), value: isRecordHovered)
        .onHover { isRecordHovered = $0 }
        .disabled(appState.recordingState == .preparing || !hasScreenPermission)
    }

    // MARK: - Recording Content

    @ViewBuilder
    private var recordingContent: some View {
        Spacer().frame(width: 8)

        // Pulsing dot + label
        HStack(spacing: 8) {
            Circle()
                .fill(VoomTheme.accentRed)
                .frame(width: 10, height: 10)
                .opacity(appState.recordingState == .paused ? 0.4 : 1.0)
                .animation(
                    appState.recordingState == .paused
                        ? .default
                        : .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                    value: appState.recordingState
                )

            Text(appState.recordingState == .paused ? "Paused" : "Recording")
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(appState.recordingState == .paused ? VoomTheme.textSecondary : .white)
                .contentTransition(.interpolate)
        }

        divider

        // Timer
        Text(appState.formattedDuration)
            .font(.system(.title3, design: .monospaced, weight: .medium))
            .foregroundStyle(.white)
            .monospacedDigit()
            .contentTransition(.numericText(countsDown: false))
            .animation(.snappy(duration: 0.25), value: appState.formattedDuration)

        divider

        // Pause/Resume
        iconButton(icon: appState.recordingState == .paused ? "play.fill" : "pause.fill", dimmed: false) {
            Task { await togglePause() }
        }

        // Stop
        Button {
            Task { await stopRecording() }
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(VoomTheme.accentRed.opacity(0.7))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Shared Components

    private var divider: some View {
        Rectangle()
            .fill(VoomTheme.borderSubtle)
            .frame(width: 1, height: 20)
            .padding(.horizontal, 8)
    }

    @ViewBuilder
    private func iconButton(icon: String, dimmed: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(dimmed ? VoomTheme.textTertiary : .white)
                .frame(width: 32, height: 32)
                .background(VoomTheme.backgroundSelected)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func toggleButton(icon: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(isOn ? Color.white : VoomTheme.textQuaternary)
                .frame(width: 32, height: 32)
                .background(isOn ? VoomTheme.borderMedium : Color.clear)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(isOn ? VoomTheme.borderSubtle : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
    }

    private var displayLabel: String {
        if let display = appState.selectedDisplay {
            if let index = appState.availableDisplays.firstIndex(where: { $0.displayID == display.displayID }) {
                return "Display \(index + 1)"
            }
            return "Display \(display.displayID)"
        }
        return "Select..."
    }

    // MARK: - Camera Preview

    private func startCameraPreview() async {
        if let existing = activeCamera {
            await existing.stopCapture()
            OverlayManager.shared.hideCameraPiPImmediate()
            activeCamera = nil
        }
        let cam = CameraCapture()
        do {
            try await cam.startCapture()
            // Pre-add mic input now so session won't reconfigure (and flicker) when recording starts
            try? await cam.prepareForMic()
            let session = cam.sessionBox.session
            self.activeCamera = cam
            if let session {
                OverlayManager.shared.showCameraPiP(
                    session: session,
                    display: appState.selectedDisplay,
                    pipPosition: appState.pipPosition
                )
            }
        } catch {
            print("[Voom] Camera preview failed: \(error)")
        }
    }

    private func stopCameraPreview() {
        OverlayManager.shared.hideCameraPiP()
        if let cam = activeCamera {
            Task { await cam.stopCapture() }
        }
        activeCamera = nil
    }

    // MARK: - Actions

    private func pickDisplay() async {
        if appState.availableDisplays.isEmpty {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                appState.availableDisplays = content.displays
                if appState.selectedDisplay == nil {
                    appState.selectedDisplay = content.displays.first
                }
            } catch {
                errorMessage = "Failed to access screen: \(error.localizedDescription)"
                return
            }
        }

        guard !appState.availableDisplays.isEmpty else { return }

        if let picked = await DisplayPicker.shared.pick(from: appState.availableDisplays) {
            appState.selectedDisplay = picked
            if appState.isCameraEnabled {
                await startCameraPreview()
            }
        }
    }

    private func startRecording() async {
        errorMessage = nil
        appState.recordingState = .preparing

        if appState.availableDisplays.isEmpty {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                appState.availableDisplays = content.displays
                if appState.selectedDisplay == nil {
                    appState.selectedDisplay = content.displays.first
                }
            } catch {
                appState.recordingState = .idle
                errorMessage = "Failed to access screen: \(error.localizedDescription)"
                return
            }
        }

        guard let display = appState.selectedDisplay ?? appState.availableDisplays.first else {
            appState.recordingState = .idle
            errorMessage = "No display found"
            return
        }

        let cameraEnabled = appState.isCameraEnabled
        var camera: CameraCapture?
        if cameraEnabled {
            if let existing = activeCamera {
                // Reuse the already-running camera — don't touch the PiP overlay
                camera = existing
            } else {
                let cam = CameraCapture()
                do {
                    try await cam.startCapture()
                    camera = cam
                    self.activeCamera = cam
                    if let session = cam.sessionBox.session {
                        OverlayManager.shared.showCameraPiP(
                            session: session,
                            display: display,
                            pipPosition: appState.pipPosition
                        )
                    }
                } catch {
                    // Camera failed, continue without it
                }
            }
        }

        await CountdownOverlay.shared.run(display: display)

        let recorder = ScreenRecorder(appState: appState)
        self.screenRecorder = recorder
        let micEnabled = appState.isMicEnabled
        let systemAudioEnabled = appState.isSystemAudioEnabled
        let pipPosition = appState.pipPosition

        do {
            nonisolated(unsafe) let captureDisplay = display
            try await recorder.startRecording(
                display: captureDisplay,
                cameraEnabled: cameraEnabled,
                micEnabled: micEnabled,
                systemAudioEnabled: systemAudioEnabled,
                pipPosition: pipPosition,
                existingCamera: camera
            )
            appState.recordingState = .recording
            appState.recordingDuration = 0
            startDurationTimer()
        } catch {
            appState.recordingState = .idle
            OverlayManager.shared.hideCameraPiP()
            if let cam = activeCamera { await cam.stopCapture() }
            activeCamera = nil
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    private func stopRecording() async {
        appState.recordingState = .stopping
        stopDurationTimer()

        var recordingID: UUID?
        if let recorder = screenRecorder {
            recordingID = await recorder.stopRecording()
        }
        screenRecorder = nil
        // activeCamera stays alive — ScreenRecorder didn't stop it
        appState.recordingState = .idle

        // PiP stays visible if camera is enabled (session is still running)
        if !appState.isCameraEnabled {
            OverlayManager.shared.hideCameraPiP()
            if let cam = activeCamera {
                Task { await cam.stopCapture() }
            }
            activeCamera = nil
        }

        if recordingID != nil {
            appState.selectedRecordingID = recordingID
            onOpenLibrary()
        }
    }

    private func togglePause() async {
        guard let recorder = screenRecorder else { return }
        if appState.recordingState == .paused {
            await recorder.resume()
            appState.recordingState = .recording
            startDurationTimer()
        } else {
            await recorder.pause()
            appState.recordingState = .paused
            stopDurationTimer()
        }
    }

    private func startDurationTimer() {
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            appState.recordingDuration += 1
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
