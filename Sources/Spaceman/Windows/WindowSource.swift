import AppKit
import CoreGraphics
import SpacemanCore

/// Enumerates the tileable windows on the *current* Space.
///
/// `CGWindowListCopyWindowInfo` with `.optionOnScreenOnly` is public API and
/// returns only on-screen windows. Since macOS 10.15 the window *name*
/// (`kCGWindowName`) is withheld without Screen Recording consent, but geometry,
/// owner PID and owner name are not — and we only need those, so the app never
/// asks for that permission.
///
/// "On screen" is not the same as "on the current Space": macOS lays Spaces
/// side by side in one virtual coordinate plane and reports neighbouring
/// Spaces' windows at off-screen offsets. So survivors of the cheap checks are
/// filtered by their exact Space tag (`CGSSpaces`, the same private API the Go
/// version uses), which is also what makes Space transitions clean — during a
/// slide both Spaces' windows report plausible geometry, but only one Space's
/// windows carry a visible tag.
///
/// Geometry alone cannot tell a document window from a dialog, so the last
/// filter classifies through the Accessibility tree (`WindowClassifier`),
/// applying the same rules as the Go version's `Tileable()`: standard subrole,
/// resizable, not a system overlay app.
@MainActor
enum WindowSource {

    /// Owners that report normal-layer windows but must never be tiled.
    private static let excludedOwners: Set<String> = [
        "Window Server", "Dock", "Spotlight", "Notification Center",
        "Control Center", "Screenshot", "loginwindow", "SystemUIServer",
        "Spaceman",
    ]

    private static let classifier = WindowClassifier()

    /// Windows smaller than this on either axis are almost always palettes,
    /// tooltips or HUDs rather than real document windows (same threshold as
    /// the Go version).
    private static let minimumSize: CGFloat = 50

    static func currentSpaceWindows() -> [ManagedWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        let displays = NSScreen.screens.map(\.frame)
        var candidates: [ManagedWindow] = []

        // The array is front-to-back, so the array index is the z-order.
        for (zOrder, entry) in raw.enumerated() {
            guard
                let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = entry[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                let number = entry[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }

            let owner = entry[kCGWindowOwnerName as String] as? String ?? "Unknown"
            guard !excludedOwners.contains(owner) else { continue }
            guard bounds.width >= minimumSize, bounds.height >= minimumSize else { continue }

            // A fully transparent window is off-screen in spirit.
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.05 { continue }

            // A window dragged mostly off every display is not on any display's
            // tiling region — see `Displays.isOnDisplay`.
            let frame = Coordinates.toAppKit(bounds)
            guard Displays.isOnDisplay(frame, displays: displays) else { continue }

            candidates.append(ManagedWindow(
                id: number,
                pid: pid,
                ownerName: owner,
                frame: frame,
                zOrder: zOrder
            ))
        }

        // Exact Space membership. A window whose tag is unknown (just created,
        // window server hasn't caught up) is skipped this pass rather than
        // guessed about — it shows up on the next one. This mirrors the Go
        // version, which never tiles a window whose Space it cannot name.
        if CGSSpaces.shared.isAvailable {
            let visible = CGSSpaces.shared.visibleSpaces()
            let tags = CGSSpaces.shared.spaces(for: candidates.map(\.id))
            candidates = candidates.compactMap { window in
                guard let spaces = tags[window.id], !spaces.isDisjoint(with: visible) else {
                    return nil
                }
                return ManagedWindow(id: window.id, pid: window.pid,
                                     ownerName: window.ownerName, frame: window.frame,
                                     zOrder: window.zOrder, spaceIDs: spaces)
            }
        }

        // The most expensive check goes last: dialogs, sheets, fixed-size
        // windows and system overlay apps are left where the user put them.
        let result = candidates.filter { classifier.isTileable($0) }

        // Keep verdicts for windows we rejected too — otherwise every dialog
        // is re-classified on the next pass.
        classifier.retain(only: Set(candidates.map(\.id)), pids: Set(candidates.map(\.pid)))
        return result
    }
}

/// Quartz (top-left origin, y down) ⇄ AppKit (bottom-left origin, y up).
///
/// `CGWindowListCopyWindowInfo` and the Accessibility API both speak Quartz.
/// `NSScreen.visibleFrame` and the layout engine speak AppKit. Getting this
/// backwards silently mirrors every window vertically, so it lives in one place
/// with one flip point.
@MainActor
enum Coordinates {

    /// Bottom edge of the global coordinate system: the primary display's top.
    private static var flipReference: CGFloat {
        NSScreen.screens.first?.frame.maxY ?? 0
    }

    static func toAppKit(_ quartz: CGRect) -> CGRect {
        CGRect(x: quartz.minX,
               y: flipReference - quartz.maxY,
               width: quartz.width,
               height: quartz.height)
    }

    static func toQuartz(_ appKit: CGRect) -> CGRect {
        CGRect(x: appKit.minX,
               y: flipReference - appKit.maxY,
               width: appKit.width,
               height: appKit.height)
    }

    static func toQuartz(point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: flipReference - point.y)
    }
}
