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
    /// PID -> executable name, for matching unbundled processes.
    private var processNames: [pid_t: String] = [:]
    /// PID -> all identities matched against the exclusion list.
    private var identityCache: [pid_t: [String]] = [:]

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

        // The user's exclusion list, which by default holds Apple's utility
        // surfaces (see `TilingExclusions.defaults`). Checked before the cache so editing
        // it in Settings takes effect on the next pass, in both directions.
        if TilingExclusions.isExcluded(ExcludedApps.effective,
                                       identities: identities(for: window)) {
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
        processNames = processNames.filter { pids.contains($0.key) }
        identityCache = identityCache.filter { pids.contains($0.key) }
        resolver.retainApps(only: pids)
    }

    /// Every name the window's process goes by, for the exclusion list: its
    /// bundle ID, the bundle IDs of apps it is nested inside, and its
    /// executable name. Cached per process.
    private func identities(for window: ManagedWindow) -> [String] {
        if let cached = identityCache[window.pid] { return cached }
        var names: [String] = []
        let app = NSRunningApplication(processIdentifier: window.pid)
        if let id = app?.bundleIdentifier { names.append(id) }
        if let path = app?.bundleURL?.path {
            names += TilingExclusions.enclosingAppPaths(of: path)
                .compactMap { Bundle(path: $0)?.bundleIdentifier }
        }
        if let name = processName(for: window) { names.append(name) }
        identityCache[window.pid] = names
        return names
    }

    /// The executable's file name — what identifies a process with no bundle,
    /// such as a command-line tool that opens a window. Falls back to the
    /// CGWindowList owner name, which is the same string for such processes.
    private func processName(for window: ManagedWindow) -> String? {
        if let cached = processNames[window.pid] { return cached }
        let name = NSRunningApplication(processIdentifier: window.pid)?
            .executableURL?.lastPathComponent ?? window.ownerName
        processNames[window.pid] = name
        return name
    }

    private func bundleIdentifier(for pid: pid_t) -> String? {
        if let cached = bundles[pid] { return cached }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        bundles[pid] = bundle
        return bundle
    }
}
