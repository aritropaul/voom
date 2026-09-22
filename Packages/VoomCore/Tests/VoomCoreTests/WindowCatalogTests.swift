import Testing
import CoreGraphics
@testable import VoomCore

struct WindowCatalogTests {

    // MARK: - Eligibility

    @Test func acceptsANormalAppWindow() {
        #expect(WindowCatalog.isEligible(
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            bundleIdentifier: "com.apple.Safari",
            ownBundleIdentifier: "com.voom.app"
        ))
    }

    @Test func rejectsNonZeroWindowLayers() {
        // The Dock (20) and menu bar (24) pass every geometric test, so the
        // layer check is what actually keeps them out of the picker.
        for layer in [-2_147_483_623, 3, 20, 24, 25] {
            #expect(!WindowCatalog.isEligible(
                layer: layer,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                isOnScreen: true,
                bundleIdentifier: "com.apple.dock.helper",
                ownBundleIdentifier: nil
            ))
        }
    }

    @Test func rejectsWindowsSmallerThanTheMinimum() {
        let tooNarrow = CGRect(x: 0, y: 0, width: 40, height: 400)
        let tooShort = CGRect(x: 0, y: 0, width: 400, height: 20)
        let statusItem = CGRect(x: 0, y: 0, width: 1, height: 1)
        for frame in [tooNarrow, tooShort, statusItem] {
            #expect(!WindowCatalog.isEligible(
                layer: 0,
                frame: frame,
                isOnScreen: true,
                bundleIdentifier: "com.example.app",
                ownBundleIdentifier: nil
            ))
        }
    }

    @Test func acceptsExactlyTheMinimumSize() {
        #expect(WindowCatalog.isEligible(
            layer: 0,
            frame: CGRect(origin: .zero, size: WindowCatalog.minimumSize),
            isOnScreen: true,
            bundleIdentifier: "com.example.app",
            ownBundleIdentifier: nil
        ))
    }

    @Test func rejectsOffScreenAndOwnerlessWindows() {
        #expect(!WindowCatalog.isEligible(
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: false,
            bundleIdentifier: "com.example.app",
            ownBundleIdentifier: nil
        ))
        #expect(!WindowCatalog.isEligible(
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            bundleIdentifier: nil,
            ownBundleIdentifier: nil
        ))
    }

    @Test func rejectsSystemChromeAndVoomItself() {
        for bundleID in WindowCatalog.excludedBundleIdentifiers {
            #expect(!WindowCatalog.isEligible(
                layer: 0,
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                isOnScreen: true,
                bundleIdentifier: bundleID,
                ownBundleIdentifier: "com.voom.app"
            ))
        }
        // Recording Voom's own control panel would be a hall of mirrors.
        #expect(!WindowCatalog.isEligible(
            layer: 0,
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            isOnScreen: true,
            bundleIdentifier: "com.voom.app",
            ownBundleIdentifier: "com.voom.app"
        ))
    }

    // MARK: - Geometry

    @Test func convertsAppKitPointsIntoCoreGraphicsSpace() {
        // 900pt-tall primary screen: AppKit's top edge (y=900) is CG's y=0.
        let top = WindowCatalog.coreGraphicsPoint(fromAppKit: CGPoint(x: 100, y: 900), primaryScreenMaxY: 900)
        #expect(top == CGPoint(x: 100, y: 0))

        let bottom = WindowCatalog.coreGraphicsPoint(fromAppKit: CGPoint(x: 100, y: 0), primaryScreenMaxY: 900)
        #expect(bottom == CGPoint(x: 100, y: 900))
    }

    @Test func pointConversionRoundTripsThroughRectConversion() {
        // A CG rect flipped to AppKit space and hit-tested with a flipped point
        // must agree — this pairing is what makes the picker's highlight line up
        // with what the click selects.
        let primaryMaxY: CGFloat = 1_080
        let cgRect = CGRect(x: 200, y: 100, width: 400, height: 300)

        let appKit = WindowCatalog.appKitRect(fromCoreGraphics: cgRect, primaryScreenMaxY: primaryMaxY)
        #expect(appKit == CGRect(x: 200, y: 680, width: 400, height: 300))

        let appKitCentre = CGPoint(x: appKit.midX, y: appKit.midY)
        let cgCentre = WindowCatalog.coreGraphicsPoint(fromAppKit: appKitCentre, primaryScreenMaxY: primaryMaxY)
        #expect(cgRect.contains(cgCentre))
    }

    @Test func rectConversionHandlesScreensAboveThePrimary() {
        // A display placed above the primary has negative CG y. The flip must
        // still land it above the primary in AppKit space.
        let cgRect = CGRect(x: 0, y: -900, width: 1_440, height: 900)
        let appKit = WindowCatalog.appKitRect(fromCoreGraphics: cgRect, primaryScreenMaxY: 900)
        #expect(appKit == CGRect(x: 0, y: 900, width: 1_440, height: 900))
    }

    // MARK: - Hit Testing

    private func window(_ id: CGWindowID, _ frame: CGRect, app: String = "App") -> CapturableWindow {
        CapturableWindow(id: id, title: "Window \(id)", appName: app, bundleIdentifier: "com.example.\(id)", frame: frame)
    }

    @Test func frontmostOverlappingWindowWins() {
        // The list is front-to-back, so the first match is the one the user sees
        // and expects to select.
        let front = window(1, CGRect(x: 0, y: 0, width: 500, height: 500))
        let back = window(2, CGRect(x: 0, y: 0, width: 800, height: 800))
        let picked = WindowCatalog.topmostWindow(at: CGPoint(x: 250, y: 250), in: [front, back])
        #expect(picked?.id == 1)

        // Outside the front window, the one behind it takes over.
        let behind = WindowCatalog.topmostWindow(at: CGPoint(x: 700, y: 700), in: [front, back])
        #expect(behind?.id == 2)
    }

    @Test func emptyDesktopHitsNothing() {
        let only = window(1, CGRect(x: 0, y: 0, width: 100, height: 100))
        #expect(WindowCatalog.topmostWindow(at: CGPoint(x: 900, y: 900), in: [only]) == nil)
        #expect(WindowCatalog.topmostWindow(at: .zero, in: []) == nil)
    }

    // MARK: - Labels

    @Test func labelsFallBackWhenTitleOrAppNameIsMissing() {
        let both = CapturableWindow(id: 1, title: "Inbox", appName: "Mail", bundleIdentifier: nil, frame: .zero)
        #expect(both.displayLabel == "Mail — Inbox")
        #expect(both.shortLabel == "Mail")

        let noTitle = CapturableWindow(id: 2, title: "", appName: "Mail", bundleIdentifier: nil, frame: .zero)
        #expect(noTitle.displayLabel == "Mail")

        let noApp = CapturableWindow(id: 3, title: "Inbox", appName: "", bundleIdentifier: nil, frame: .zero)
        #expect(noApp.displayLabel == "Inbox")
        #expect(noApp.shortLabel == "Inbox")

        let neither = CapturableWindow(id: 7, title: "", appName: "", bundleIdentifier: nil, frame: .zero)
        #expect(neither.displayLabel == "Window 7")
        #expect(neither.shortLabel == "Window")
    }
}
