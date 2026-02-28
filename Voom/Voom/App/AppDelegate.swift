import AppKit
import SwiftUI
import os

private let logger = Logger(subsystem: "com.voom.app", category: "AppDelegate")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    let store = RecordingStore.shared
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("[Voom] AppDelegate.applicationDidFinishLaunching called")
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

        let openItem = NSMenuItem(title: "Open Voom", action: #selector(openLibrary), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        let locationItem = NSMenuItem(title: "Recording Location", action: #selector(openRecordingLocation), keyEquivalent: "")
        locationItem.target = self
        menu.addItem(locationItem)

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
        NSApp.activate(ignoringOtherApps: true)
        WindowActions.openWindow?(id: "library")
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    @objc private func openRecordingLocation() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Movies")
            .appendingPathComponent("Voom")
        NSWorkspace.shared.open(dir)
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
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
