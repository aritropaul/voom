import SwiftUI
import AVFoundation
import VoomCore
import VoomApp
import VoomMeetings

struct ControlPanelView: View {
    @Environment(AppState.self) private var appState
    @State private var session = RecordingSessionController.shared
    @State private var isRecordHovered = false
    @State private var showSavePreset = false
    @State private var presetName = ""

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
                if appState.isCameraEnabled {
                    Task { await session.startCameraPreview() }
                }
            }
            .onDisappear {
                if !isRecordingActive {
                    session.stopCameraPreview()
                }
            }
            .onChange(of: appState.isCameraEnabled) { _, enabled in
                if enabled {
                    Task { await session.startCameraPreview() }
                } else {
                    session.stopCameraPreview()
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
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.05))
                        ControlPanelManager.shared.recenterPanel(appState: appState)
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopRecordingFromMenuBar)) { _ in
                if isRecordingActive {
                    Task { await stopAndOpenLibrary() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRecordingFromHotkey)) { _ in
                if isRecordingActive {
                    Task { await stopAndOpenLibrary() }
                } else if appState.canStartRecording {
                    Task { await session.startRecording() }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startRecordingFromMeeting)) { _ in
                if appState.canStartRecording {
                    Task { await session.startRecording(skipCountdown: true) }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoStopMeetingRecording)) { _ in
                if isRecordingActive {
                    Task { await stopAndOpenLibrary() }
                }
            }
            .alert("Recording Error", isPresented: Binding(
                get: { session.errorMessage != nil },
                set: { if !$0 { session.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { session.errorMessage = nil }
            } message: {
                Text(session.errorMessage ?? "")
            }
            .alert("Save Preset", isPresented: $showSavePreset) {
                TextField("Preset name", text: $presetName)
                Button("Save") {
                    guard !presetName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let preset = RecordingPreset(
                        name: presetName.trimmingCharacters(in: .whitespaces),
                        recordingMode: appState.recordingMode,
                        isCameraEnabled: appState.isCameraEnabled,
                        isMicEnabled: appState.isMicEnabled,
                        isSystemAudioEnabled: appState.isSystemAudioEnabled,
                        pipPosition: appState.pipPosition
                    )
                    PresetStore.shared.add(preset)
                    presetName = ""
                }
                Button("Cancel", role: .cancel) {
                    presetName = ""
                }
            } message: {
                Text("Enter a name for this recording configuration.")
            }
    }

    private func stopAndOpenLibrary() async {
        let recordingID = await session.stopRecording()
        if let recordingID {
            appState.selectedRecordingID = recordingID
            onOpenLibrary()
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
            session.stopCameraPreview()
            onDismiss()
        }

        // Open library
        iconButton(icon: "square.grid.2x2", dimmed: true) {
            onOpenLibrary()
        }

        // Presets
        Menu {
            let presetStore = PresetStore.shared
            ForEach(presetStore.presets) { preset in
                Button(preset.name) {
                    appState.recordingMode = preset.recordingMode
                    appState.isCameraEnabled = preset.isCameraEnabled
                    appState.isMicEnabled = preset.isMicEnabled
                    appState.isSystemAudioEnabled = preset.isSystemAudioEnabled
                    appState.pipPosition = preset.pipPosition
                }
            }

            if !presetStore.presets.isEmpty {
                Divider()
            }

            Button("Save Current as Preset...") {
                showSavePreset = true
            }

            if !presetStore.presets.isEmpty {
                Menu("Manage...") {
                    ForEach(presetStore.presets) { preset in
                        Button("Delete \"\(preset.name)\"", role: .destructive) {
                            presetStore.delete(preset)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .foregroundStyle(VoomTheme.textSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .fixedSize()

        divider

        // Mode picker
        modePicker

        divider

        // Toggle buttons
        HStack(spacing: 2) {
            if appState.recordingMode != .cameraOnly {
                toggleButton(icon: "camera.fill", isOn: appState.isCameraEnabled) {
                    appState.isCameraEnabled.toggle()
                }
            }
            toggleButton(icon: "mic.fill", isOn: appState.isMicEnabled) {
                appState.isMicEnabled.toggle()
            }
            if appState.recordingMode != .cameraOnly {
                toggleButton(icon: "speaker.wave.2.fill", isOn: appState.isSystemAudioEnabled) {
                    appState.isSystemAudioEnabled.toggle()
                }
            }
        }

        // PiP position (only if camera on and not cam-only mode)
        if appState.isCameraEnabled && appState.recordingMode != .cameraOnly {
            divider

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
        }

        // Display selector (hidden for cam-only)
        if appState.recordingMode != .cameraOnly {
            divider

            Button {
                Task { await session.pickDisplay() }
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
        }

        divider

        // Record button
        Button {
            Task { await session.startRecording() }
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
        .disabled(appState.recordingState == .preparing)
    }

    // MARK: - Mode Picker

    @ViewBuilder
    private var modePicker: some View {
        HStack(spacing: 2) {
            modeButton(icon: "display", mode: .fullScreen)
            modeButton(icon: "rectangle.dashed", mode: .region)
            modeButton(icon: "camera.fill", mode: .cameraOnly)
        }
    }

    @ViewBuilder
    private func modeButton(icon: String, mode: RecordingMode) -> some View {
        Button {
            appState.recordingMode = mode
        } label: {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(appState.recordingMode == mode ? .white : VoomTheme.textQuaternary)
                .frame(width: 28, height: 28)
                .background(appState.recordingMode == mode ? VoomTheme.borderMedium : Color.clear)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(appState.recordingMode == mode ? VoomTheme.borderSubtle : Color.clear, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
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

        // Annotation toggle (screen modes only)
        if appState.recordingMode != .cameraOnly {
            toggleButton(icon: "pencil.tip", isOn: appState.isAnnotating) {
                appState.isAnnotating.toggle()
                if appState.isAnnotating {
                    OverlayManager.shared.showAnnotationOverlay()
                } else {
                    OverlayManager.shared.hideAnnotationOverlay()
                }
            }
        }

        // Pause/Resume
        iconButton(icon: appState.recordingState == .paused ? "play.fill" : "pause.fill", dimmed: false) {
            Task { await session.togglePause() }
        }

        // Stop
        Button {
            Task { await stopAndOpenLibrary() }
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
}
