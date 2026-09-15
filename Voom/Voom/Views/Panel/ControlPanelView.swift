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
    @State private var cameras: [CameraDeviceInfo] = []
    @State private var microphones: [MicDeviceInfo] = []
    @State private var audioOutputs: [AudioOutputDeviceInfo] = []
    @State private var selectedAudioOutputID: String?
    @State private var audioOutputError: String?
    @State private var showAudioSettings = false
    @AppStorage("VoiceStudio") private var voiceEnhance = true

    let onOpenLibrary: () -> Void
    let onQuit: () -> Void
    let onDismiss: () -> Void

    private var isRecordingActive: Bool {
        appState.recordingState == .recording || appState.recordingState == .paused
    }

    var body: some View {
        styledBar
            .onAppear(perform: startPreviewIfNeeded)
            .task {
                // Bluetooth can change its microphone profile after the first
                // connection event. Refresh while the panel is visible as well.
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                    guard !isRecordingActive else { continue }
                    refreshMicrophones()
                    refreshAudioOutputs()
                }
            }
            .onDisappear(perform: stopPreviewIfIdle)
            .onChange(of: appState.isCameraEnabled) { _, enabled in
                syncCameraPreview(enabled: enabled || appState.recordingMode == .cameraOnly)
            }
            .onChange(of: appState.selectedCameraDeviceID) { oldValue, newValue in
                guard oldValue != newValue, usesCamera else { return }
                Task { await session.startCameraPreview() }
            }
            .onChange(of: appState.recordingMode) { _, _ in
                syncCameraPreview(enabled: usesCamera)
            }
            .onReceive(NotificationCenter.default.publisher(for: MicDeviceCatalog.devicesDidChangeNotification)) { _ in
                refreshMicrophones()
            }
            .onReceive(NotificationCenter.default.publisher(for: AudioOutputDeviceCatalog.devicesDidChangeNotification)) { _ in
                refreshAudioOutputs()
            }
            .onChange(of: appState.pipPosition, handlePiPPositionChange)
            .onChange(of: appState.recordingState, handleRecordingStateChange)
            .modifier(ControlPanelNotifications(
                refreshDevices: {
                    refreshCameras()
                    refreshMicrophones()
                    refreshAudioOutputs()
                },
                onStop: { Task { await stopAndOpenLibrary() } },
                onToggleHotkey: {
                    if isRecordingActive {
                        Task { await stopAndOpenLibrary() }
                    } else if appState.canStartRecording {
                        Task { await session.startRecording() }
                    }
                },
                onMeetingStart: {
                    if appState.canStartRecording {
                        Task { await session.startRecording(skipCountdown: true) }
                    }
                },
                onMeetingAutoStop: {
                    if isRecordingActive {
                        Task { await stopAndOpenLibrary() }
                    }
                }
            ))
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
                Button("Save") { savePreset() }
                Button("Cancel", role: .cancel) { presetName = "" }
            } message: {
                Text("Enter a name for this recording configuration.")
            }
            .alert("Audio Output", isPresented: Binding(
                get: { audioOutputError != nil },
                set: { if !$0 { audioOutputError = nil } }
            )) {
                Button("OK", role: .cancel) { audioOutputError = nil }
            } message: {
                Text(audioOutputError ?? "")
            }
    }

    private var styledBar: some View {
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
    }

    private func startPreviewIfNeeded() {
        MicDeviceCatalog.startObservingHardwareChanges()
        AudioOutputDeviceCatalog.startObservingHardwareChanges()
        refreshCameras()
        refreshMicrophones()
        refreshAudioOutputs()
        if usesCamera {
            Task { await session.startCameraPreview() }
        }
    }

    private func stopPreviewIfIdle() {
        if !isRecordingActive {
            session.stopCameraPreview()
        }
    }

    private func syncCameraPreview(enabled: Bool) {
        if enabled {
            Task { await session.startCameraPreview() }
        } else {
            session.stopCameraPreview()
        }
    }

    private func handlePiPPositionChange(_: PiPPosition, _ newPosition: PiPPosition) {
        guard appState.isCameraEnabled, OverlayManager.shared.isCameraShowing else { return }
        OverlayManager.shared.moveCameraPiP(to: newPosition)
    }

    private func handleRecordingStateChange(_ oldValue: RecordingState, _ newValue: RecordingState) {
        let wasRecording = oldValue == .recording || oldValue == .paused
        let isNowRecording = newValue == .recording || newValue == .paused
        guard wasRecording != isNowRecording else { return }
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.updateStatusIcon(recording: isNowRecording)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.05))
            ControlPanelManager.shared.recenterPanel(appState: appState)
        }
    }

    private func savePreset() {
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
        }

        divider
        audioSettingsButton

        if usesCamera {
            divider
            cameraPicker
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

    // MARK: - Camera Picker

    private var usesCamera: Bool {
        appState.recordingMode == .cameraOnly || appState.isCameraEnabled
    }

    @ViewBuilder
    private var cameraPicker: some View {
        Menu {
            ForEach(cameras) { camera in
                Button {
                    appState.selectedCameraDeviceID = camera.uniqueID
                } label: {
                    if camera.uniqueID == appState.selectedCameraDeviceID {
                        Label(camera.localizedName, systemImage: "checkmark")
                    } else {
                        Text(camera.localizedName)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video")
                    .font(.system(size: 11))
                Text(cameraLabel)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
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
        .onAppear(perform: refreshCameras)
    }

    private var cameraLabel: String {
        if let selected = cameras.first(where: { $0.uniqueID == appState.selectedCameraDeviceID }) {
            return shortCameraName(selected.localizedName)
        }
        return cameras.first.map { shortCameraName($0.localizedName) } ?? "Camera"
    }

    private func shortCameraName(_ name: String) -> String {
        name.count <= 18 ? name : String(name.prefix(16)) + "…"
    }

    private func refreshCameras() {
        cameras = CameraDeviceCatalog.availableDevices()
    }

    // MARK: - Audio Settings

    private var audioSettingsButton: some View {
        Button {
            refreshMicrophones()
            refreshAudioOutputs()
            showAudioSettings.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "waveform")
                Text("Audio")
                    .fontWeight(.semibold)
                Text(appState.isMicEnabled ? shortCameraName(microphoneLabel) : "Mic off")
                    .foregroundStyle(VoomTheme.textSecondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(VoomTheme.backgroundHover)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Choose the recording microphone, computer audio, and playback output.")
        .popover(isPresented: $showAudioSettings, arrowEdge: .top) {
            audioSettingsPanel
        }
    }

    private var audioSettingsPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Audio for this recording")
                    .font(.headline)
                Spacer()
                Button("Done") { showAudioSettings = false }
            }

            VStack(alignment: .leading, spacing: 8) {
                Toggle("Record microphone", isOn: Binding(
                    get: { appState.isMicEnabled },
                    set: { appState.isMicEnabled = $0 }
                ))
                Picker("Record from", selection: Binding(
                    get: {
                        appState.selectedMicrophoneDeviceID.map { selectedMicrophoneID ?? $0 }
                            ?? "voom.automatic-microphone"
                    },
                    set: { value in
                        appState.selectedMicrophoneDeviceID = value == "voom.automatic-microphone" ? nil : value
                        appState.isMicEnabled = true
                    }
                )) {
                    Text("Automatic (prefer laptop mic)").tag("voom.automatic-microphone")
                    ForEach(microphones) { microphone in
                        Text(microphone.localizedName).tag(microphone.uniqueID)
                    }
                    if let missingID = appState.selectedMicrophoneDeviceID, selectedMicrophoneID == nil {
                        Text("Selected microphone unavailable").tag(missingID)
                    }
                }
                .disabled(!appState.isMicEnabled)
                Text("This microphone records your voice.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Enhance voice", isOn: $voiceEnhance)
                    .disabled(!appState.isMicEnabled)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Picker("Listen through", selection: Binding(
                    get: { selectedAudioOutputID ?? "voom.system-output" },
                    set: { value in selectAudioOutput(value) }
                )) {
                    if !audioOutputs.contains(where: { $0.uniqueID == selectedAudioOutputID }) {
                        Text("Current Mac output").tag(selectedAudioOutputID ?? "voom.system-output")
                    }
                    ForEach(audioOutputs) { output in
                        Text(output.localizedName).tag(output.uniqueID)
                    }
                }
                Text("Where you hear playback. Choose your recording microphone above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if appState.recordingMode != .cameraOnly {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    Toggle("Record computer audio", isOn: Binding(
                        get: { recordsComputerAudio },
                        set: { appState.isSystemAudioEnabled = $0 }
                    ))
                    .disabled(appState.isMeetingRecording)
                    Text(appState.isMeetingRecording
                         ? "Computer audio is included in meeting recordings."
                         : "Includes sound from other apps, videos, and calls. Turn off for voice-only recordings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("What will be saved")
                    .font(.subheadline.weight(.semibold))
                Text(recordedAudioSummary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoomTheme.backgroundHover)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack {
                Button("Refresh devices") {
                    refreshMicrophones()
                    refreshAudioOutputs()
                }
                Spacer()
                Button("Connect headphones…", action: openBluetoothSettings)
            }
            .font(.caption)
        }
        .toggleStyle(.switch)
        .padding(20)
        .frame(width: 400)
        .preferredColorScheme(.dark)
    }

    private var recordedAudioSummary: String {
        var sources: [String] = []
        if appState.isMicEnabled {
            sources.append(selectedMicrophoneID == nil
                           ? "Microphone unavailable. Choose a connected microphone."
                           : "Voice from \(microphoneLabel)")
        }
        if recordsComputerAudio {
            sources.append("Computer audio")
        }
        return sources.isEmpty ? "Video only. No audio will be recorded." : sources.joined(separator: "\n")
    }

    private var recordsComputerAudio: Bool {
        appState.recordingMode != .cameraOnly && (appState.isMeetingRecording || appState.isSystemAudioEnabled)
    }

    private var selectedMicrophoneID: String? {
        MicDeviceCatalog.recordingDevice(
            preferredID: appState.selectedMicrophoneDeviceID,
            devices: microphones
        )?.uniqueID
    }

    private var microphoneLabel: String {
        if let selected = microphones.first(where: { $0.uniqueID == selectedMicrophoneID }) {
            return selected.localizedName
        }
        return "Unavailable microphone"
    }

    private func refreshMicrophones() {
        microphones = MicDeviceCatalog.availableDevices()
    }

    private func selectAudioOutput(_ uniqueID: String) {
        do {
            try AudioOutputDeviceCatalog.selectDevice(uniqueID: uniqueID)
        } catch {
            audioOutputError = error.localizedDescription
        }
        refreshAudioOutputs()
    }

    private func refreshAudioOutputs() {
        audioOutputs = AudioOutputDeviceCatalog.availableDevices()
        selectedAudioOutputID = AudioOutputDeviceCatalog.currentDeviceID()
    }

    private func openBluetoothSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") else { return }
        NSWorkspace.shared.open(url)
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

private struct ControlPanelNotifications: ViewModifier {
    let refreshDevices: () -> Void
    let onStop: () -> Void
    let onToggleHotkey: () -> Void
    let onMeetingStart: () -> Void
    let onMeetingAutoStop: () -> Void

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasConnectedNotification)) { _ in
                refreshDevices()
            }
            .onReceive(NotificationCenter.default.publisher(for: AVCaptureDevice.wasDisconnectedNotification)) { _ in
                refreshDevices()
            }
            .onReceive(NotificationCenter.default.publisher(for: .stopRecordingFromMenuBar)) { _ in
                onStop()
            }
            .onReceive(NotificationCenter.default.publisher(for: .toggleRecordingFromHotkey)) { _ in
                onToggleHotkey()
            }
            .onReceive(NotificationCenter.default.publisher(for: .startRecordingFromMeeting)) { _ in
                onMeetingStart()
            }
            .onReceive(NotificationCenter.default.publisher(for: .autoStopMeetingRecording)) { _ in
                onMeetingAutoStop()
            }
    }
}
