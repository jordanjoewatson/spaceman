import AppKit
import SwiftUI
import SpacemanCore

/// The app's preference store: typed access to `UserDefaults`, plus change
/// notification for the things that have to react.
///
/// This is the whole of what the Go version's `internal/config/` package did.
/// The parser, the strict `-check-config` validator, the annotated default file
/// and the 700ms reload watcher all have no counterpart: values arrive typed
/// from the registration domain (see `DefaultsSchema`), and `cfprefsd` posts
/// `didChangeNotification` on write, so live reload is a subscription rather
/// than a poll. Nothing here parses, validates, or watches a file.
///
/// `ObservableObject` so SwiftUI settings panes bind straight to it; `onChange`
/// for the AppKit controllers (bars, tiler) that need to act on a new value
/// rather than redraw.
@MainActor
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults: UserDefaults

    /// Called after any preference changes, for controllers that must do work —
    /// re-tile, resize bars — rather than simply re-render. A list rather than a
    /// single closure because more than one controller needs to react and
    /// nothing should have to know who else is listening.
    private var observers: [() -> Void] = []

    /// Subscribe to preference changes. Handlers live as long as the store,
    /// which outlives every controller, so they must capture weakly.
    func observe(_ handler: @escaping () -> Void) {
        observers.append(handler)
    }

    /// `defaults` is injectable so tests can run against a throwaway suite
    /// instead of the user's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: Defaults.registration)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(defaultsChanged),
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// External `defaults write`, and an MDM profile landing a managed value.
    @objc private func defaultsChanged() {
        announceChange()
    }

    /// Tell SwiftUI and the controllers that something moved.
    ///
    /// Called directly from the setters below rather than left to
    /// `didChangeNotification`. The notification is documented to carry the
    /// `UserDefaults` instance as its object, but that is not reliable across
    /// releases, and an observer registered for a specific object silently
    /// receives nothing when it isn't — which shows up as the whole app
    /// refusing to react to its own Settings window. In-process correctness
    /// should not rest on that; the notification stays for outside writes.
    private func announceChange() {
        objectWillChange.send()
        for observer in observers { observer() }
    }

    // MARK: - Typed access

    subscript(key: DefaultsKey<Bool>) -> Bool {
        get { defaults.bool(forKey: key.name) }
        set { defaults.set(newValue, forKey: key.name); announceChange() }
    }

    subscript(key: DefaultsKey<Double>) -> Double {
        get { Defaults.clamp(defaults.double(forKey: key.name), for: key) }
        set {
            defaults.set(Defaults.clamp(newValue, for: key), forKey: key.name)
            announceChange()
        }
    }

    subscript(key: DefaultsKey<String>) -> String {
        get { defaults.string(forKey: key.name) ?? key.fallback }
        set { defaults.set(newValue, forKey: key.name); announceChange() }
    }

    /// A `Binding` for the numeric controls in the settings panes.
    func binding(_ key: DefaultsKey<Double>) -> Binding<Double> {
        Binding(get: { self[key] }, set: { self[key] = $0 })
    }

    /// Forget a setting, restoring the registered default. This is what a
    /// "Reset" button does — and the reason it can exist at all is that the
    /// default was never written to disk in the first place.
    func reset(_ name: String) {
        defaults.removeObject(forKey: name)
        announceChange()
    }

    // MARK: - Dynamic keys
    //
    // Shortcut overrides are one key per command, so their names are not known
    // at compile time and cannot be `DefaultsKey`s.

    /// nil when nothing has been stored, which is distinct from a stored zero.
    func rawValue(forKey name: String) -> Any? {
        defaults.object(forKey: name)
    }

    func integer(forKey name: String) -> Int {
        defaults.integer(forKey: name)
    }

    func setInteger(_ value: Int, forKey name: String) {
        defaults.set(value, forKey: name)
        announceChange()
    }

    // MARK: - Derived values

    /// Layout parameters for the tiler, assembled from the individual settings.
    var layoutParams: LayoutParams {
        LayoutParams(masterRatio: self[Defaults.masterRatio],
                     gap: self[Defaults.gap],
                     outerGap: self[Defaults.outerGap])
    }

    /// The layout a Space starts in. Parsed with the same tolerant spelling
    /// table as `commands.json` and `spaceman://` URLs, so `defaults write
    /// tiling.defaultLayout master` works as typed.
    var defaultLayout: LayoutMode {
        LayoutMode(userInput: self[Defaults.defaultLayout]) ?? .spaceman
    }

    /// Window move animation, gated by the system's Reduce Motion setting.
    ///
    /// An accessibility preference outranks an app one: a user who has asked the
    /// whole system to stop animating has already answered this question.
    var animationsEnabled: Bool {
        get {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return false }
            return self[Defaults.animationEnabled]
        }
        set { self[Defaults.animationEnabled] = newValue }
    }

    var animationDuration: TimeInterval { self[Defaults.animationDuration] }

    /// User-defined open-app chords. JSON in `apps.shortcuts`; a corrupt value
    /// degrades to none, the same as a corrupt custom-preset list.
    var appShortcuts: [AppShortcut] {
        get { AppShortcut.decodeList(self[Defaults.appShortcuts]) }
        set { self[Defaults.appShortcuts] = AppShortcut.encodeList(newValue) }
    }

    /// Per-display vertical nudges for the top and bottom bars.
    var barDisplayOffsets: [String: DisplayBarOffsets] {
        get { DisplayBarOffsetStore.decode(self[Defaults.barDisplayOffsets]) }
        set { self[Defaults.barDisplayOffsets] = DisplayBarOffsetStore.encode(newValue) }
    }

    func barOffsets(for displayID: CGDirectDisplayID) -> DisplayBarOffsets {
        barDisplayOffsets[String(displayID)] ?? DisplayBarOffsets()
    }

    func setBarOffset(_ value: Double, for displayID: CGDirectDisplayID,
                      edge: BarPlacement.Edge) {
        var all = barDisplayOffsets
        var offsets = all[String(displayID)] ?? DisplayBarOffsets()
        let clamped = min(max(value, -200), 200)
        switch edge {
        case .top:    offsets.top = clamped
        case .bottom: offsets.bottom = clamped
        }
        if offsets == DisplayBarOffsets() {
            all.removeValue(forKey: String(displayID))
        } else {
            all[String(displayID)] = offsets
        }
        barDisplayOffsets = all
    }

}

/// The bar's background material, as a name that survives a round trip through
/// `defaults write`.
///
/// A material rather than a colour because materials are what make the bars read
/// as system chrome: they pick up desktop tinting, adapt to dark mode, and
/// collapse to an opaque surface when the user turns on Reduce Transparency —
/// none of which a painted colour does.
enum BarMaterial: String, CaseIterable {
    case hudWindow, sidebar, headerView, menu, popover, underWindowBackground, windowBackground

    var material: NSVisualEffectView.Material {
        switch self {
        case .hudWindow:              return .hudWindow
        case .sidebar:                return .sidebar
        case .headerView:             return .headerView
        case .menu:                   return .menu
        case .popover:                return .popover
        case .underWindowBackground:  return .underWindowBackground
        case .windowBackground:       return .windowBackground
        }
    }

    var title: String {
        switch self {
        case .hudWindow:              return "HUD"
        case .sidebar:                return "Sidebar"
        case .headerView:             return "Header"
        case .menu:                   return "Menu"
        case .popover:                return "Popover"
        case .underWindowBackground:  return "Under Window"
        case .windowBackground:       return "Window"
        }
    }
}
