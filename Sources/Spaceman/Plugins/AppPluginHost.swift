import AppKit
import ApplicationServices
import PluginKit
import SpacemanCore

/// The live `PluginHost`: backs the plugin contract with the app's real
/// controllers. Kept deliberately thin — everything here is an adaptation of
/// something the tiler already does.
@MainActor
final class AppPluginHost: PluginHost {

    private let tiler: TilingController
    private let resolver = AXWindowResolver()
    private let noteHandler: (String) -> Void

    /// Built once and handed to every plugin, so they all repaint together when
    /// the palette changes.
    private(set) lazy var palette = PluginPalette { [weak self] role in
        self?.color(role) ?? .labelColor
    }

    init(tiler: TilingController, note: @escaping (String) -> Void) {
        self.tiler = tiler
        self.noteHandler = note
    }

    /// Tell plugin views the palette moved. Wired to the preference observer, so
    /// switching palette in Settings repaints plugin windows immediately rather
    /// than the next time they open.
    func paletteChanged() {
        palette.refresh()
    }

    /// Windows on the current Space, titled via the Accessibility tree (the
    /// permission the tiler already holds — `CGWindowListCopyWindowInfo` alone
    /// withholds titles without Screen Recording consent).
    var windows: [PluginWindow] {
        WindowSource.currentSpaceWindows().map { window in
            var title = ""
            if let element = resolver.windowElement(pid: window.pid, id: window.id),
               let value = copyAttribute(element, kAXTitleAttribute) as? String {
                title = value
            }
            return PluginWindow(id: window.id, title: title, appName: window.ownerName)
        }
    }

    /// Raise the window and activate its app — the same two steps as clicking
    /// its Dock tile.
    func focusWindow(_ id: CGWindowID) {
        guard let window = WindowSource.currentSpaceWindows().first(where: { $0.id == id }) else {
            return
        }
        if let element = resolver.windowElement(pid: window.pid, id: window.id) {
            AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        }
        NSRunningApplication(processIdentifier: window.pid)?
            .activate(options: [.activateIgnoringOtherApps])
    }

    /// The window-manager verbs a palette may offer — the Go cmdProvider's
    /// list (zoom, minimize, re-tile) plus layout cycling.
    var wmActions: [PluginAction] {
        [
            PluginAction(title: "Zoom / fullscreen window") { [weak tiler] in tiler?.toggleZoom() },
            PluginAction(title: "Minimize window") { [weak tiler] in tiler?.minimizeFocused() },
            PluginAction(title: "Re-tile windows") { [weak tiler] in tiler?.tileNow() },
            PluginAction(title: "Cycle layout") { [weak tiler] in tiler?.cycleLayout() },
        ]
    }

    func swapState() -> PluginSwapState {
        let (focused, rects) = tiler.swapCandidates()
        let windows = WindowSource.currentSpaceWindows()
        let byID = Dictionary(windows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let candidates = rects.compactMap { id, frame -> PluginTiledWindow? in
            guard let window = byID[id] else { return nil }
            var title = ""
            if let element = resolver.windowElement(pid: window.pid, id: window.id),
               let value = copyAttribute(element, kAXTitleAttribute) as? String {
                title = value
            }
            return PluginTiledWindow(id: id, title: title,
                                     appName: window.ownerName, frame: frame)
        }
        // Sorted so an overlay builds its views in a stable order rather than
        // following dictionary hashing, which would reshuffle between passes.
        return PluginSwapState(focused: focused, candidates: candidates.sorted { $0.id < $1.id })
    }

    func tiledNeighbor(of id: CGWindowID, direction: PluginDirection) -> CGWindowID? {
        let mapped: FocusDirection
        switch direction {
        case .left:  mapped = .left
        case .right: mapped = .right
        case .up:    mapped = .up
        case .down:  mapped = .down
        }
        return tiler.tiledNeighbor(of: id, direction: mapped)
    }

    func swapWindows(_ a: CGWindowID, _ b: CGWindowID) {
        tiler.swap(a, b)
    }

    func note(_ message: String) {
        noteHandler(message)
    }

    func showScene(_ id: String) {
        PluginSurface.shared.showScene(id)
    }

    func toggleScene(_ id: String) {
        PluginSurface.shared.toggleScene(id)
    }

    /// Resolved against the active palette, so a plugin panel follows the theme
    /// the user picked rather than painting its own colours.
    func color(_ role: PluginColorRole) -> NSColor {
        let palette = Preferences.shared.activePalette
        let themeRole: ThemeRole
        switch role {
        case .background: themeRole = .background
        case .surface:    themeRole = .surface
        case .text:       themeRole = .text
        case .muted:      themeRole = .muted
        case .accent:     themeRole = .accent
        case .good:       themeRole = .good
        case .warn:       themeRole = .warn
        case .danger:     themeRole = .danger
        case .separator:  themeRole = .separator
        }
        return Theme.nsColor(themeRole, in: palette)
    }

    /// `~/Library/Application Support/Spaceman/Plugins/<name>/`.
    ///
    /// One directory per plugin rather than a shared folder: removing a plugin
    /// becomes deleting a directory, and no plugin can collide with another's
    /// files. Created on demand, so a plugin that never stores anything leaves
    /// no trace.
    func dataDirectory(for pluginName: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
        let directory = base
            .appendingPathComponent("Spaceman", isDirectory: true)
            .appendingPathComponent("Plugins", isDirectory: true)
            .appendingPathComponent(pluginName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        return directory
    }

    private func copyAttribute(_ element: AXUIElement, _ name: String) -> Any? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }
}
