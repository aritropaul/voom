import AppKit
import AVFoundation
import SwiftUI
@preconcurrency import ScreenCaptureKit
import UserNotifications
import Sparkle
import EventKit
import os
import VoomCore
import VoomAI
import VoomMeetings

private let logger = Logger(subsystem: "com.voom.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let store = RecordingStore.shared
    private var statusItem: NSStatusItem?
    static private(set) var shared: AppDelegate!
    let updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("[Voom] AppDelegate.applicationDidFinishLaunching called")
        AppDelegate.shared = self
        updaterController.updater.automaticallyChecksForUpdates = false
        // Disable macOS window restoration so onboarding doesn't reappear
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "record.circle", accessibilityDescription: "Voom")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            logger.notice("[Voom] Status item button configured")
        } else {
            logger.error("[Voom] Status item button is nil!")
        }

        // Register global hotkey (Cmd+Shift+R)
        let hotkeyEnabled = UserDefaults.standard.object(forKey: "GlobalHotkeyEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "GlobalHotkeyEnabled")
        if hotkeyEnabled {
            GlobalHotkey.shared.register()
        }

        // Request all permissions upfront on launch
        requestPermissions()

        // Start view notification polling if enabled
        let viewNotificationsEnabled = UserDefaults.standard.object(forKey: "ViewNotificationsEnabled") == nil ? true : UserDefaults.standard.bool(forKey: "ViewNotificationsEnabled")
        if viewNotificationsEnabled {
            Task {
                await ViewNotificationService.shared.requestNotificationPermission()
                await ViewNotificationService.shared.startPolling()
            }
        }

        // Start meeting detection polling if enabled
        if appState.meetingDetectionEnabled {
            Task {
                await configureMeetingDetection()
                await MeetingDetectionService.shared.startPolling()
            }
        }

        // Wire OpenRouter AI provider if configured
        if AIConfig.isConfigured {
            Task {
                await TextAnalysisService.shared.setExternalProvider(AIService.shared)
            }
        }

        // Show onboarding on first launch only
        if !appState.hasCompletedOnboarding {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(0.5))
                WindowActions.openWindow?(id: "onboarding")
            }
        }
    }

    private func requestPermissions() {
        // Screen recording
        CGRequestScreenCaptureAccess()

        // Camera
        AVCaptureDevice.requestAccess(for: .video) { _ in }

        // Microphone
        AVCaptureDevice.requestAccess(for: .audio) { _ in }

        // Accessibility (for cursor tracking)
        _ = AXIsProcessTrusted()
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp {
            showContextMenu()
        } else {
            handleLeftClick()
        }
    }

    private func handleLeftClick() {
        // If recording, stop it
        if appState.canStopRecording {
            NotificationCenter.default.post(name: .stopRecordingFromMenuBar, object: nil)
            return
        }
        ControlPanelManager.shared.toggle(appState: appState)
    }

    private func showContextMenu() {
        let menu = NSMenu()

        // Show next meeting at top of menu when meeting detection is on
        if appState.meetingDetectionEnabled, let upcoming = appState.upcomingMeeting {
            let meetingView = MenuBarMeetingView(meeting: upcoming)
            let hostingView = NSHostingView(rootView: meetingView)
            hostingView.appearance = NSAppearance(named: .darkAqua)
            let size = hostingView.fittingSize
            hostingView.frame = NSRect(origin: .zero, size: size)
            let meetingItem = NSMenuItem()
            meetingItem.view = hostingView
            menu.addItem(meetingItem)
            menu.addItem(.separator())
        }

        let openItem = NSMenuItem(title: "Open Voom", action: #selector(openLibrary), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let locationItem = NSMenuItem(title: "Recording Location", action: #selector(openRecordingLocation), keyEquivalent: "")
        locationItem.target = self
        menu.addItem(locationItem)

        let updateItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        updateItem.target = self
        menu.addItem(updateItem)

        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Voom", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        // Clear menu so left-click goes back to action-based handling
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func openLibrary() {
        NSApp.activate()
        WindowActions.openWindow?(id: "library")
    }

    @objc private func openSettings() {
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openRecordingLocation() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        NSWorkspace.shared.open(dir)
    }

    @objc private func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }

    @objc private func openMeetingURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func configureMeetingDetection() async {
        let state = appState
        let callbacks = MeetingDetectionCallbacks(
            onMeetingDetected: { detected in
                state.detectedMeeting = detected
                MeetingPanelManager.shared.show(meeting: detected, appState: state)
            },
            onAutoStopRequested: {
                NotificationCenter.default.post(name: .autoStopMeetingRecording, object: nil)
            },
            onCameraOff: {
                state.detectedMeeting = nil
                MeetingPanelManager.shared.dismiss()
            },
            onUpcomingMeetingChanged: { upcoming in
                state.upcomingMeeting = upcoming
            },
            getRecordingState: {
                state.recordingState
            },
            getIsMeetingRecording: {
                state.isMeetingRecording
            }
        )
        await MeetingDetectionService.shared.setCallbacks(callbacks)
    }

    func updateStatusIcon(recording: Bool) {
        let name = recording ? "record.circle.fill" : "record.circle"
        statusItem?.button?.image = NSImage(systemSymbolName: name, accessibilityDescription: "Voom")
        statusItem?.button?.contentTintColor = recording ? .red : nil
    }
}

extension Notification.Name {
    static let stopRecordingFromMenuBar = Notification.Name("stopRecordingFromMenuBar")
}
