import SwiftUI

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
                    NSApp.setActivationPolicy(.regular)
                }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)

        Window("Voom Library", id: "library") {
            LibraryWindow()
                .environment(appDelegate.appState)
                .environment(appDelegate.store)
                .preferredColorScheme(.dark)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                }
                .onDisappear {
                    // Switch back to accessory if no visible windows remain
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
                    .environment(appDelegate.appState)
                    .environment(appDelegate.store)
                    .preferredColorScheme(.dark)
                    .frame(minWidth: 600, minHeight: 400)
                    .onAppear {
                        NSApp.setActivationPolicy(.regular)
                    }
                    .onDisappear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
