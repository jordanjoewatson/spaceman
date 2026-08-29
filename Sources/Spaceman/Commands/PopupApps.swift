import AppKit
import SpacemanCore

/// Bundle IDs whose windows must not be tiled — the live set of popup shortcuts.
///
/// Checked on every classify so adding or removing a popup in Settings takes
/// effect on the next tiling pass, without waiting for a relaunch. The chord
/// itself still registers at launch, like every other shortcut.
@MainActor
enum PopupApps {

    private static var bundleIDs: Set<String> = []
    private static var paths: Set<String> = []

    static func sync(_ shortcuts: [AppShortcut]) {
        let popups = shortcuts.filter { $0.kind == .popup }
        bundleIDs = Set(popups.compactMap(\.bundleIdentifier).filter { !$0.isEmpty })
        paths = Set(popups.map(\.path))
    }

    static func owns(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        if let id = app.bundleIdentifier, bundleIDs.contains(id) { return true }
        if let url = app.bundleURL {
            let path = url.resolvingSymlinksInPath().path
            return paths.contains(where: {
                URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == path
            })
        }
        return false
    }
}
