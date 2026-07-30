import SwiftUI
import AVFoundation
import VoomCore
import VoomApp
import VoomMeetings
import os
@preconcurrency import ScreenCaptureKit

private let sessionLogger = Logger(subsystem: "com.voom.app", category: "RecordingSession")

/// Owns the lifecycle of every recorder type plus the shared camera preview.
/// Views render state and forward intents; AppDelegate uses `stopForQuit()` to
/// guarantee an in-flight recording is finalized before the process exits.
@Observable @MainActor
final class RecordingSessionController {
    static let shared = RecordingSessionController()
    private init() {}

    @ObservationIgnored private var appState: AppState!

    // Lifecycle internals, not UI state — @ObservationIgnored so writes during
    // recording transitions don't invalidate every view observing this object
    // (only errorMessage below is rendered).
    @ObservationIgnored private(set) var screenRecorder: ScreenRecorder?
    @ObservationIgnored private(set) var cameraOnlyRecorder: CameraOnlyRecorder?
    @ObservationIgnored private(set) var meetingRecorder: MeetingRecorder?
    @ObservationIgnored private(set) var activeCamera: CameraCapture?
    @ObservationIgnored private var durationTimer: Timer?

    /// Set on any start/stop failure; ControlPanelView presents it as an alert.
    var errorMessage: String?

    var hasActiveRecorder: Bool {
        screenRecorder != nil || cameraOnlyRecorder != nil || meetingRecorder != nil
    }

    func configure(appState: AppState) {
        self.appState = appState
    }

    // MARK: - Camera Preview

    func startCameraPreview() async {
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
            sessionLogger.error("[Voom] Camera preview failed: \(error.localizedDescription)")
        }
    }

    func stopCameraPreview() {
        OverlayManager.shared.hideCameraPiP()
        if let cam = activeCamera {
            Task { await cam.stopCapture() }
        }
        activeCamera = nil
    }

    // MARK: - Display Picking

    func pickDisplay() async {
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

    // MARK: - Start

    func startRecording(skipCountdown: Bool = false) async {
        errorMessage = nil
        appState.recordingState = .preparing

        // Camera-only mode
        if appState.recordingMode == .cameraOnly {
            await startCameraOnlyRecording()
            return
        }

        // Region mode — show selector first
        if appState.recordingMode == .region {
            if let display = appState.selectedDisplay ?? appState.availableDisplays.first {
                let selector = RegionSelector()
                nonisolated(unsafe) let captureDisplay = display
                if let rect = await selector.selectRegion(on: captureDisplay) {
                    appState.selectedRegion = rect
                } else {
                    appState.recordingState = .idle
                    return
                }
            }
        }

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
                    sessionLogger.warning("[Voom] Camera unavailable, recording without it: \(error.localizedDescription)")
                }
            }
        }

        if !skipCountdown {
            await CountdownOverlay.shared.run(display: display)
        }

        let micEnabled = appState.isMicEnabled

        if appState.isMeetingRecording {
            // Meeting path: use MeetingRecorder (HD/2K, 30fps, split-track diarization)
            let recorder = MeetingRecorder(stateProvider: appState)
            self.meetingRecorder = recorder

            do {
                nonisolated(unsafe) let captureDisplay = display
                try await recorder.startRecording(
                    display: captureDisplay,
                    micEnabled: micEnabled
                )
                appState.recordingState = .recording
                appState.recordingDuration = 0
                startDurationTimer()
            } catch {
                appState.recordingState = .idle
                OverlayManager.shared.hideCameraPiP()
                if let cam = activeCamera { await cam.stopCapture() }
                activeCamera = nil
                meetingRecorder = nil
                errorMessage = "Recording failed: \(error.localizedDescription)"
            }
        } else {
            // Regular screen recording path
            let recorder = ScreenRecorder(stateProvider: appState)
            self.screenRecorder = recorder
            let systemAudioEnabled = appState.isSystemAudioEnabled
            let pipPosition = appState.pipPosition
            let cropRect = appState.selectedRegion
            let pipWinNum = OverlayManager.shared.cameraPanelWindowNumber
            let annotationWinNum = OverlayManager.shared.annotationWindowNumber

            do {
                nonisolated(unsafe) let captureDisplay = display
                try await recorder.startRecording(
                    display: captureDisplay,
                    cameraEnabled: cameraEnabled,
                    micEnabled: micEnabled,
                    systemAudioEnabled: systemAudioEnabled,
                    pipPosition: pipPosition,
                    existingCamera: camera,
                    cropRect: cropRect,
                    pipWindowNumber: pipWinNum,
                    annotationWindowNumber: annotationWinNum
                )
                appState.recordingState = .recording
                appState.recordingDuration = 0
                startDurationTimer()
            } catch {
                appState.recordingState = .idle
                OverlayManager.shared.hideCameraPiP()
                if let cam = activeCamera { await cam.stopCapture() }
                activeCamera = nil
                screenRecorder = nil
                errorMessage = "Recording failed: \(error.localizedDescription)"
            }
        }
    }

    private func startCameraOnlyRecording() async {
        var camera: CameraCapture?
        if let existing = activeCamera {
            camera = existing
        } else {
            let cam = CameraCapture()
            do {
                try await cam.startCapture()
                camera = cam
                self.activeCamera = cam
            } catch {
                appState.recordingState = .idle
                errorMessage = "Camera failed: \(error.localizedDescription)"
                return
            }
        }

        let recorder = CameraOnlyRecorder(stateProvider: appState)
        self.cameraOnlyRecorder = recorder
        let micEnabled = appState.isMicEnabled

        do {
            try await recorder.startRecording(
                micEnabled: micEnabled,
                existingCamera: camera
            )
            appState.recordingState = .recording
            appState.recordingDuration = 0
            startDurationTimer()
        } catch {
            appState.recordingState = .idle
            if let cam = activeCamera { await cam.stopCapture() }
            activeCamera = nil
            cameraOnlyRecorder = nil
            errorMessage = "Recording failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Stop

    /// Stops the active recorder and returns the saved recording's ID.
    /// A finalize failure surfaces in `errorMessage`; a salvageable file is
    /// still saved (see the recorders' salvage path).
    @discardableResult
    func stopRecording() async -> UUID? {
        appState.recordingState = .stopping
        stopDurationTimer()

        var recordingID: UUID?
        do {
            if let recorder = cameraOnlyRecorder {
                recordingID = try await recorder.stopRecording()
                cameraOnlyRecorder = nil
            } else if let recorder = meetingRecorder {
                recordingID = try await recorder.stopRecording()
                meetingRecorder = nil
            } else if let recorder = screenRecorder {
                recordingID = try await recorder.stopRecording()
                screenRecorder = nil
            }
        } catch {
            cameraOnlyRecorder = nil
            meetingRecorder = nil
            screenRecorder = nil
            sessionLogger.error("[Voom] Stop failed: \(error.localizedDescription)")
            errorMessage = "Recording could not be saved: \(error.localizedDescription)"
        }

        appState.recordingState = .idle
        appState.selectedRegion = nil
        appState.isMeetingRecording = false

        // PiP stays visible if camera is enabled (session is still running)
        if !appState.isCameraEnabled || appState.recordingMode == .cameraOnly {
            OverlayManager.shared.hideCameraPiP()
            if let cam = activeCamera {
                Task { await cam.stopCapture() }
            }
            activeCamera = nil
        }

        return recordingID
    }

    /// Quit path: silently stop and save any in-flight recording, then flush
    /// pending library writes. Never blocks quit on failure — best effort,
    /// always-save semantics.
    func stopForQuit() async {
        if hasActiveRecorder {
            sessionLogger.notice("[Voom] Quit requested while recording — finalizing first")
            await stopRecording()
        }
        await RecordingStore.shared.flush()
    }

    // MARK: - Pause

    func togglePause() async {
        let pausing = appState.recordingState != .paused
        if let recorder = cameraOnlyRecorder {
            if pausing { await recorder.pause() } else { await recorder.resume() }
        } else if let recorder = meetingRecorder {
            if pausing { await recorder.pause() } else { await recorder.resume() }
        } else if let recorder = screenRecorder {
            if pausing { await recorder.pause() } else { await recorder.resume() }
        } else {
            return
        }
        appState.recordingState = pausing ? .paused : .recording
        if pausing { stopDurationTimer() } else { startDurationTimer() }
    }

    // MARK: - Duration Timer

    private func startDurationTimer() {
        durationTimer?.invalidate()
        let state = appState!
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                state.recordingDuration += 1
            }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
    }
}
