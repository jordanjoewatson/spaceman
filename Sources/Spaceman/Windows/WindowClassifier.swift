import AppKit
import ApplicationServices
import SpacemanCore

/// Decides whether a window should be tiled, matching the Go version's
/// `Tileable()` (`internal/core/store/store.go`).
///
/// `CGWindowList` geometry alone cannot tell a document window from a dialog,
/// so the first time a window is seen its AX element is resolved once and the
/// verdict is cached by CGWindowID (subrole and resizability do not change over
/// a window's lifetime). A window that cannot be resolved is left alone until
/// it can — tiling an unclassified Open panel or Xcode popup is worse than
/// placing a new document one pass late.
@MainActor
final class WindowClassifier {

    private let resolver = AXWindowResolver()

    /// CGWindowID -> tileable verdict. Failures are not cached, so a window
    /// seen before Accessibility consent lands gets classified properly later.
    private var verdicts: [CGWindowID: Bool] = [:]
    /// PID -> bundle identifier, looked up once per process.
    private var bundles: [pid_t: String?] = [:]

    /// Apple utility surfaces that behave like overlays rather than documents:
    /// single-window, often fixed-size, and expected on top of the desktop
    /// instead of taking a slot in the grid. Ported from the Go version's
    /// `SystemFloatBundles` — matched as bundle id prefixes, so e.g. every
    /// System Settings extension is covered by its parent.
    private static let systemFloatBundles = [
        "com.apple.systempreferences", // System Settings
        "com.apple.SystemProfiler",    // About This Mac / System Information
        "com.apple.ActivityMonitor",
        "com.apple.AboutThisMacLauncher",
        "com.apple.finder.SaveDialog",
        "com.apple.KeychainAccess",
        "com.apple.ScreenSharing",
        "com.apple.screencaptureui",   // screenshot UI
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.PhotoBooth",
        "com.apple.Dictionary",
        "com.apple.calculator",
        "com.apple.ColorSyncUtility",
        "com.apple.AirPortBaseStationAgent",
        "com.apple.print",             // print dialogs / Printer Setup
        "com.apple.DiskUtility",
        "com.apple.audio.AudioMIDISetup",
        "com.apple.appkit.xpc.openAndSavePanelService",
        "com.apple.SecurityAgent",
        "com.apple.coreservices.uiagent",
        "com.apple.UserNotificationCenter",
    ]

    /// Whether `window` should take a slot in the layout.
    ///
    /// The minimized check the Go version does is already handled upstream:
    /// minimized windows are not on screen, so `CGWindowList(.optionOnScreenOnly)`
    /// never reports them.
    func isTileable(_ window: ManagedWindow) -> Bool {
        if let verdict = verdicts[window.id] { return verdict }

        // Our own windows are never tiled. Settings, the help sheet and any
        // plugin panel are standard resizable windows, so every other rule here
        // says yes to them — and a window manager that rearranges its own
        // Settings window while you are using it is indefensible.
        guard window.pid != ProcessInfo.processInfo.processIdentifier else {
            verdicts[window.id] = false
            return false
        }

        // Popup-app windows are floats by user choice, not by AX role. Checked
        // before the cache so adding a popup shortcut in Settings un-tiles
        // an already-classified window on the next pass.
        if PopupApps.owns(pid: window.pid) {
            return false
        }

        let bundle = bundleIdentifier(for: window.pid)
        if let bundle, Self.systemFloatBundles.contains(where: { bundle.hasPrefix($0) }) {
            verdicts[window.id] = false
            return false
        }

        guard let element = resolver.windowElement(pid: window.pid, id: window.id) else {
            // Fail closed and do not cache: a dialog we cannot name must not
            // take a grid slot. A real window shows up on the next pass.
            return false
        }

        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, "AXSubrole" as CFString, &subrole)

        var modal: CFTypeRef?
        let isModal =
            AXUIElementCopyAttributeValue(element, "AXModal" as CFString, &modal) == .success
            && (modal as? Bool) == true

        var sizeSettable = DarwinBoolean(true)
        let sizeQuery = AXUIElementIsAttributeSettable(
            element, kAXSizeAttribute as CFString, &sizeSettable)
        var positionSettable = DarwinBoolean(true)
        let positionQuery = AXUIElementIsAttributeSettable(
            element, kAXPositionAttribute as CFString, &positionSettable)
        guard sizeQuery == .success, positionQuery == .success else {
            return false
        }

        let verdict = WindowRules.isDocumentWindow(
            role: role as? String,
            subrole: subrole as? String,
            isModal: isModal,
            resizable: sizeSettable.boolValue,
            movable: positionSettable.boolValue
        )
        verdicts[window.id] = verdict
        return verdict
    }

    /// Forget windows (and their apps) that no longer exist.
    func retain(only live: Set<CGWindowID>, pids: Set<pid_t>) {
        verdicts = verdicts.filter { live.contains($0.key) }
        bundles = bundles.filter { pids.contains($0.key) }
        resolver.retainApps(only: pids)
    }

    private func bundleIdentifier(for pid: pid_t) -> String? {
        if let cached = bundles[pid] { return cached }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundles[pid] = bundle
        return bundle
    }
}
