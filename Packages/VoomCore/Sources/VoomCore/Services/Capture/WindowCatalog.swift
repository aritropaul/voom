import Foundation
@preconcurrency import ScreenCaptureKit

// MARK: - Capturable Window

/// A snapshot of one shareable window, safe to hold in UI state.
///
/// `SCWindow` is a live object whose frame goes stale the moment the user moves
/// the window, so the picker stores this value type and the recorder re-resolves
/// the real `SCWindow` by `id` when capture starts.
public struct CapturableWindow: Identifiable, Hashable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let bundleIdentifier: String?
    /// CoreGraphics global display coordinates (top-left origin), in points.
    public let frame: CGRect

    public init(id: CGWindowID, title: String, appName: String, bundleIdentifier: String?, frame: CGRect) {
        self.id = id
        self.title = title
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.frame = frame
    }

    /// Short name for the control panel — the app, which is what users scan for.
    public var shortLabel: String {
        appName.isEmpty ? (title.isEmpty ? "Window" : title) : appName
    }

    /// Full name for the picker overlay and the recording indicator.
    public var displayLabel: String {
        switch (appName.isEmpty, title.isEmpty) {
        case (false, false): "\(appName) — \(title)"
        case (false, true): appName
        case (true, false): title
        case (true, true): "Window \(id)"
        }
    }
}

// MARK: - Window Catalog

/// Enumerates the windows worth offering in a picker, and re-resolves a picked
/// window to a live `SCWindow` at capture time.
public enum WindowCatalog {
    /// Windows narrower or shorter than this are status-item backing stores,
    /// shadow-only helpers and 1×1 probes — never something a user means to record.
    public static let minimumSize = CGSize(width: 80, height: 40)

    /// Owners that publish full-screen or click-through windows at the normal
    /// layer. They pass every geometric test and are never a recording target.
    static let excludedBundleIdentifiers: Set<String> = [
        "com.apple.dock",
        "com.apple.WindowManager",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.systemuiserver",
        "com.apple.wallpaper.agent"
    ]

    /// Pure eligibility test — the whole heuristic, isolated so it can be tested
    /// without a live window server.
    ///
    /// `layer` is `SCWindow.windowLayer`: normal app windows sit at 0, while the
    /// Dock (20), menu bar (24), HUDs and the desktop all sit elsewhere.
    public static func isEligible(
        layer: Int,
        frame: CGRect,
        isOnScreen: Bool,
        bundleIdentifier: String?,
        ownBundleIdentifier: String?
    ) -> Bool {
        guard layer == 0 else { return false }
        guard isOnScreen else { return false }
        guard frame.width >= minimumSize.width, frame.height >= minimumSize.height else { return false }
        guard let bundleIdentifier, !bundleIdentifier.isEmpty else { return false }
        guard !excludedBundleIdentifiers.contains(bundleIdentifier) else { return false }
        if let ownBundleIdentifier, bundleIdentifier == ownBundleIdentifier { return false }
        return true
    }

    /// Windows the user can pick, in front-to-back order.
    ///
    /// Order is preserved from ScreenCaptureKit (frontmost first) because the
    /// picker hit-tests the cursor against it — the topmost window under the
    /// pointer has to win.
    public static func availableWindows() async throws -> [CapturableWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let ownBundleID = Bundle.main.bundleIdentifier
        return content.windows.compactMap { window in
            guard isEligible(
                layer: window.windowLayer,
                frame: window.frame,
                isOnScreen: window.isOnScreen,
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                ownBundleIdentifier: ownBundleID
            ) else { return nil }
            return CapturableWindow(
                id: window.windowID,
                title: window.title ?? "",
                appName: window.owningApplication?.applicationName ?? "",
                bundleIdentifier: window.owningApplication?.bundleIdentifier,
                frame: window.frame
            )
        }
    }

    // MARK: - Geometry

    /// `SCWindow.frame` lives in CoreGraphics display space (top-left origin,
    /// y growing downward) while every AppKit value — `NSEvent.mouseLocation`,
    /// `NSScreen.frame`, panel frames — lives in AppKit space (bottom-left
    /// origin). Mixing the two silently mirrors hit-testing across the middle of
    /// the screen, so both conversions live here and are covered by tests.
    ///
    /// `primaryScreenMaxY` is `NSScreen.screens[0].frame.maxY` — the height of
    /// the primary screen, which is the shared origin of both spaces.
    public static func coreGraphicsPoint(fromAppKit point: CGPoint, primaryScreenMaxY: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenMaxY - point.y)
    }

    /// Inverse of `coreGraphicsPoint(fromAppKit:primaryScreenMaxY:)` for rects.
    public static func appKitRect(fromCoreGraphics rect: CGRect, primaryScreenMaxY: CGFloat) -> CGRect {
        CGRect(
            x: rect.origin.x,
            y: primaryScreenMaxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    /// The frontmost window containing `point`, given a front-to-back list.
    ///
    /// `point` must already be in CoreGraphics space — the same space as
    /// `CapturableWindow.frame`.
    public static func topmostWindow(at point: CGPoint, in windows: [CapturableWindow]) -> CapturableWindow? {
        windows.first { $0.frame.contains(point) }
    }

    /// The live `SCWindow` for a previously-picked id, or nil if it has closed.
    ///
    /// Always call this immediately before building a content filter: a window
    /// picked seconds ago may have been resized, moved to another display, or
    /// closed outright.
    public static func resolve(id: CGWindowID) async throws -> SCWindow? {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
        return content.windows.first { $0.windowID == id }
    }
}
