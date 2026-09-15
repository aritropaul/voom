import AppKit
import CoreGraphics

public enum ScreenCaptureAccess {
    public static var isGranted: Bool {
        CGPreflightScreenCaptureAccess()
    }

    public static let deniedMessage =
        "Allow Screen Recording for this Voom app in System Settings, then quit and reopen Voom. If access is already enabled but recording still fails after an app update, remove the outdated entry and add the current app again."

    /// Prompts if needed. Opens System Settings when still denied.
    @discardableResult
    public static func ensure() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if CGRequestScreenCaptureAccess() { return true }
        openSystemSettings()
        return false
    }

    public static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for string in candidates {
            if let url = URL(string: string), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}
