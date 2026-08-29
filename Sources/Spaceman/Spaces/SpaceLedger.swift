import AppKit
import SpacemanCore

/// Stable identity for the current macOS Space **of each display**, from
/// `CGSCopyManagedDisplaySpaces` — the same private family of calls the Go
/// version makes.
///
/// With "Displays have separate Spaces" (the default) every display shows its
/// own Space, so identity is resolved per display: each bar labels its own
/// screen, and per-Space layout memory keys off the display's own Space rather
/// than whichever display happens to hold keyboard focus. When the setting is
/// off (or the API is missing) every display resolves to the same globally
/// active Space and behaviour collapses to the single-Space model.
///
/// We do not create, destroy, or switch Spaces — the user's real Spaces stay
/// the base. This only labels them so a layout choice can be remembered per
/// Space. Identity comes from the window server itself, so it stays correct
/// through Space transitions without any settling window, and the same Space
/// keeps the same id for as long as the Space exists.
@MainActor
final class SpaceLedger {

    /// A Space identity: the window server's own id, plus a small sequential
    /// label for display ("S1", "S2", …) in first-visited order.
    struct SpaceID: Hashable, CustomStringConvertible {
        let raw: UInt64
        let index: Int
        var description: String { "S\(index)" }
    }

    /// Fires after any display's current Space changes.
    var onSpaceChange: (() -> Void)?

    /// The current Space per display, refreshed by `resolveAll`.
    private(set) var currentByDisplay: [CGDirectDisplayID: SpaceID] = [:]
    /// User Spaces on each display, Mission Control order, for the bar dots.
    private(set) var spacesByDisplay: [CGDirectDisplayID: [SpaceID]] = [:]

    /// CGS id -> label, so each Space keeps its display name between visits.
    private var known: [UInt64: SpaceID] = [:]
    private var nextIndex = 1

    init() {
        if !CGSSpaces.shared.isAvailable {
            // Everything still tiles; per-Space memory just collapses to one
            // global identity. Never expected on a supported macOS.
            Log.debug("CGS space APIs unavailable; per-Space layouts disabled")
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(activeSpaceDidChange),
            name: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    /// Re-read every connected display's current Space in one WindowServer
    /// round-trip. A display the API doesn't know (or when it's unavailable)
    /// falls back to the globally active Space.
    ///
    /// Called on every tiling pass: the round-trip is cheap, and reading fresh
    /// is what keeps labels and layout memory correct through Space
    /// transitions with no settling window — even if a notification is missed.
    @discardableResult
    func resolveAll() -> [CGDirectDisplayID: SpaceID] {
        let perDisplay = CGSSpaces.shared.currentSpacesByDisplay()
        let lists = CGSSpaces.shared.userSpacesByDisplay()
        let fallback = CGSSpaces.shared.activeSpace() ?? 0
        for screen in NSScreen.screens {
            let currentRaw = perDisplay[screen.displayID] ?? fallback
            currentByDisplay[screen.displayID] = label(for: currentRaw)
            let ordered = lists[screen.displayID] ?? [currentRaw]
            spacesByDisplay[screen.displayID] = ordered.map { label(for: $0) }
        }
        return currentByDisplay
    }

    /// The Space currently shown on `display`, per the last `resolveAll`.
    func current(for displayID: CGDirectDisplayID) -> SpaceID {
        if let id = currentByDisplay[displayID] { return id }
        return resolveAll()[displayID] ?? label(for: CGSSpaces.shared.activeSpace() ?? 0)
    }

    /// The Space receiving keyboard input — hotkey-driven actions apply here.
    func active() -> SpaceID {
        label(for: CGSSpaces.shared.activeSpace() ?? 0)
    }

    private func label(for raw: UInt64) -> SpaceID {
        if let id = known[raw] { return id }
        let id = SpaceID(raw: raw, index: nextIndex)
        nextIndex += 1
        known[raw] = id
        return id
    }

    @objc private func activeSpaceDidChange() {
        // The notification can land a hair before the window server flips the
        // active Space, so give it one turn of the runloop to catch up.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.resolveAll()
            self.onSpaceChange?()
        }
    }

    /// Whether the current Space is a full-screen Space, which the OS lays out
    /// itself and we must leave alone.
    ///
    /// Screen geometry cannot answer this. A full-screen Space has no menu-bar
    /// or Dock inset, so `visibleFrame == frame` — but so does an ordinary Space
    /// on a Mac with both set to auto-hide, which is a common TWM setup. Keying
    /// off geometry disables tiling entirely for those users.
    ///
    /// The window list is the reliable signal: a full-screen Space contains
    /// exactly one tileable window and it covers the whole display. Two or more
    /// windows means an ordinary Space, even if one of them is maximised — and a
    /// maximised window is something a tiler *should* re-tile.
    static func isFullScreenSpace(windows: [ManagedWindow], screen: NSScreen) -> Bool {
        guard windows.count == 1, let only = windows.first else { return false }
        return abs(only.frame.width - screen.frame.width) < 2
            && abs(only.frame.height - screen.frame.height) < 2
    }
}

extension NSScreen {
    /// The CoreGraphics display number, stable for a physical connection.
    var displayID: CGDirectDisplayID {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
    }
}
