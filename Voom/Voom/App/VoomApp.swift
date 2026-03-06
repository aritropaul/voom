import SwiftUI
import VoomCore
import WhatsNewKit

/// Shared storage for the SwiftUI openWindow action, accessible from non-SwiftUI code.
@MainActor
enum WindowActions {
    static var openWindow: OpenWindowAction?
}

@main
struct VoomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        let _ = captureOpenWindow()

        Window("Welcome to Voom", id: "onboarding") {
            OnboardingView()
                .environment(appDelegate.appState)
                .preferredColorScheme(.dark)
                .onAppear {
                    // If onboarding already completed, macOS restored this window — close it
                    if appDelegate.appState.hasCompletedOnboarding {
                        Task { @MainActor in
                            for window in NSApp.windows where !(window is NSPanel) && window.identifier?.rawValue.contains("onboarding") != false {
                                window.close()
                            }
                        }
                    } else {
                        NSApp.setActivationPolicy(.regular)
                    }
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(.suppressed)

        Window("Voom Library", id: "library") {
            LibraryWindow()
                .overlay { ToastOverlay() }
                .environment(appDelegate.appState)
                .environment(appDelegate.store)
                .environment(\.whatsNew, WhatsNewEnvironment(versionStore: UserDefaultsWhatsNewVersionStore(), whatsNewCollection: self))
                .whatsNewSheet()
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                }
                .onDisappear {
                    // Switch back to accessory if no visible windows remain
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(0.1))
                        let hasVisibleWindows = NSApp.windows.contains {
                            $0.isVisible && !($0 is NSPanel)
                        }
                        if !hasVisibleWindows {
                            NSApp.setActivationPolicy(.accessory)
                        }
                    }
                }
        }
        .defaultSize(width: 960, height: 600)

        WindowGroup("Player", id: "player", for: UUID.self) { $recordingID in
            if let recordingID {
                PlayerView(recordingID: recordingID)
                    .overlay { ToastOverlay() }
                    .environment(appDelegate.appState)
                    .environment(appDelegate.store)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 600, minHeight: 400)
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                    }
                    .onDisappear {
                        Task { @MainActor in
                            try? await Task.sleep(for: .seconds(0.1))
                            let hasVisibleWindows = NSApp.windows.contains {
                                $0.isVisible && !($0 is NSPanel)
                            }
                            if !hasVisibleWindows {
                                NSApp.setActivationPolicy(.accessory)
                            }
                        }
                    }
            }
        }
        .defaultSize(width: 960, height: 600)

        Settings {
            SettingsView()
                .preferredColorScheme(.dark)
        }
    }

    @MainActor
    private func captureOpenWindow() {
        WindowActions.openWindow = openWindow
    }
}
