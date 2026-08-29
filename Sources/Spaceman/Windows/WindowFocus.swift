import AppKit
import ApplicationServices

/// Focused-window detection and focus/minimize by window identity — the Swift
/// port of the Go version's store helpers (`store_focused_window`,
/// `store_focus`, `store_minimize` in `internal/core/store/native_darwin.c`).
///
/// AX calls are thread-safe IPC, so nothing here is actor-bound; the
/// genie-animation-blocking minimize is meant to be called off the main thread.
enum WindowFocus {

    /// The focused window's owner pid and CGWindowID, or nil.
    ///
    /// The frontmost pid comes from NSWorkspace, not the system-wide AX
    /// focused-application query, which returns nothing for some apps
    /// (Electron/VS Code) — the same finding the Go version documents.
    static func focused() -> (pid: pid_t, id: CGWindowID)? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)

        // 1) The app's focused window, if it exposes one.
        // 2) The main window (Electron usually exposes this).
        // 3) Last resort: the first window that yields a CGWindowID.
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = copyElement(app, attribute), let id = windowID(of: window) {
                return (pid, id)
            }
        }
        if let windows = copyAttribute(app, kAXWindowsAttribute) as? [AXUIElement] {
            for window in windows {
                if let id = windowID(of: window) { return (pid, id) }
            }
        }
        return nil
    }

    /// Raise the window, mark it main, and front its app — the full "user
    /// clicked it" treatment. Both the AX frontmost write and NSWorkspace
    /// activation, because Electron apps (VS Code) ignore one or the other.
    static func focus(pid: pid_t, id: CGWindowID) {
        guard let window = find(pid: pid, id: id) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        NSRunningApplication(processIdentifier: pid)?.activate(options: [.activateIgnoringOtherApps])
    }

    /// Give a window the keyboard without raising it.
    ///
    /// The difference from `focus` is the missing `AXRaise`: the window becomes
    /// the one that types, but does not jump above whatever is overlapping it.
    /// That is what makes focus-follows-mouse tolerable — otherwise every pass
    /// of the pointer reshuffles the z-order.
    static func focusWithoutRaise(pid: pid_t, id: CGWindowID) {
        guard let window = find(pid: pid, id: id) else { return }
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        AXUIElementSetAttributeValue(app, kAXFocusedWindowAttribute as CFString, window)
        NSRunningApplication(processIdentifier: pid)?.activate()
    }

    /// Minimize a window. The AX write blocks for the genie animation — call
    /// it off the main thread.
    @discardableResult
    static func minimize(pid: pid_t, id: CGWindowID) -> Bool {
        setMinimized(pid: pid, id: id, true)
    }

    /// Restore a minimized window.
    @discardableResult
    static func unminimize(pid: pid_t, id: CGWindowID) -> Bool {
        setMinimized(pid: pid, id: id, false)
    }

    /// Every AX window this process will name, including minimized ones.
    ///
    /// `CGWindowList(.optionOnScreenOnly)` cannot see the Dock, so a popup
    /// toggle that has to restore a hidden app has to ask Accessibility.
    static func windows(pid: pid_t) -> [(id: CGWindowID, minimized: Bool)] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = copyAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else {
            return []
        }
        return windows.compactMap { window in
            guard let id = windowID(of: window) else { return nil }
            return (id, isMinimized(window))
        }
    }

    private static func setMinimized(pid: pid_t, id: CGWindowID, _ minimized: Bool) -> Bool {
        guard let window = find(pid: pid, id: id) else { return false }
        return AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString,
                                            minimized ? kCFBooleanTrue : kCFBooleanFalse) == .success
    }

    private static func isMinimized(_ window: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString,
                                            &value) == .success
        else { return false }
        return (value as? Bool) == true
    }

    /// Move a window's origin, leaving its size alone. `point` is in Quartz
    /// coordinates (top-left origin), as AX expects. Used for display-to-
    /// display moves: macOS re-tags the window onto the Space of whatever
    /// display its frame lands on, so no private Space-move API is needed.
    @discardableResult
    static func setPosition(pid: pid_t, id: CGWindowID, _ point: CGPoint) -> Bool {
        guard let window = find(pid: pid, id: id) else { return false }
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return false }
        return AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString,
                                            value) == .success
    }

    /// Match a CoreGraphics window number to its AX element by walking the
    /// owning app's window list — the same approach as `AXWindowResolver`, but
    /// self-contained so it can run off the main actor.
    private static func find(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let windows = copyAttribute(app, kAXWindowsAttribute) as? [AXUIElement] else { return nil }
        for candidate in windows where windowID(of: candidate) == id {
            return candidate
        }
        return nil
    }

    /// A single AX element attribute, typed. (The cast can't fail in practice:
    /// these attributes are AXUIElementRef by API contract, and a conditional
    /// downcast to a CoreFoundation type is rejected by the compiler as
    /// vacuous.)
    private static func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func windowID(of element: AXUIElement) -> CGWindowID? {
        var id = CGWindowID(0)
        return _AXUIElementGetWindow(element, &id) == .success && id != 0 ? id : nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
