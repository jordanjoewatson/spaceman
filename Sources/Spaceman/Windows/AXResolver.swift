import ApplicationServices
import Foundation

/// Resolves CGWindowIDs to their Accessibility elements, shared by the mover
/// (which writes frames) and the classifier (which reads window attributes).
///
/// Resolution walks the owning app's whole window list — several IPC
/// round-trips — so application elements are cached with a short messaging
/// timeout, and callers are expected to cache per-window results themselves.
/// `_AXUIElementGetWindow` is the same AX-framework SPI the Go version uses to
/// pair an AXUIElement with its CGWindowID.
@MainActor
final class AXWindowResolver {

    private var appCache: [pid_t: AXUIElement] = [:]

    /// Application elements are cached with a short messaging timeout, so an
    /// unresponsive app cannot stall the caller for the default 6 seconds.
    func appElement(for pid: pid_t) -> AXUIElement {
        if let cached = appCache[pid] { return cached }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        appCache[pid] = app
        return app
    }

    /// Match a CoreGraphics window number to its AX element by walking the
    /// owning app's window list and comparing `_AXUIElementGetWindow`'s id.
    func windowElement(pid: pid_t, id: CGWindowID) -> AXUIElement? {
        let app = appElement(for: pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement]
        else { return nil }

        for candidate in windows {
            var wid = CGWindowID(0)
            if _AXUIElementGetWindow(candidate, &wid) == .success, wid == id {
                return candidate
            }
        }
        return nil
    }

    /// Forget applications whose windows have all gone away.
    func retainApps(only pids: Set<pid_t>) {
        appCache = appCache.filter { pids.contains($0.key) }
    }
}

/// The same AX-framework SPI the Go version uses to pair an AXUIElement with
/// its CGWindowID. Internal (not file-private) so `WindowFocus` shares it.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError
