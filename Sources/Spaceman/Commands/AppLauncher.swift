import AppKit
import PluginKit
import SpacemanCore

/// Opens a user-defined app shortcut: activate the running instance, or launch.
///
/// Unlike the launcher, this does not spawn a second copy. A chord meant to
/// summon a daily-driver app should bring the existing one forward.
enum AppLauncher {

    static func open(_ shortcut: AppShortcut, note: @escaping (String) -> Void) {
        if let running = runningApp(for: shortcut) {
            running.activate()
            return
        }

        guard let url = applicationURL(for: shortcut) else {
            note("\(shortcut.name) is no longer installed")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            guard let error else { return }
            DispatchQueue.main.async {
                note("Could not open \(shortcut.name): \(error.localizedDescription)")
            }
        }
    }

    /// Toggle an untiled popup: show and float, or minimize.
    ///
    /// Not running → launch, leave untiled, raise. Visible → minimize.
    /// Minimized or hidden → restore and raise. The same chord does both.
    static func togglePopup(_ shortcut: AppShortcut, note: @escaping (String) -> Void) {
        if let running = runningApp(for: shortcut) {
            if isShowing(running) {
                hide(running)
            } else {
                show(running)
            }
            return
        }

        guard let url = applicationURL(for: shortcut) else {
            note("\(shortcut.name) is no longer installed")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { app, error in
            if let error {
                DispatchQueue.main.async {
                    note("Could not open \(shortcut.name): \(error.localizedDescription)")
                }
                return
            }
            DispatchQueue.main.async {
                guard let app else { return }
                waitForWindows(pid: app.processIdentifier, attempts: 20) {
                    show(app)
                }
            }
        }
    }

    /// Plugin commands for the current shortcut list. Built each launch so a
    /// Settings edit is picked up the next time chords are registered.
    static func commands(_ shortcuts: [AppShortcut],
                         note: @escaping (String) -> Void) -> [PluginCommand] {
        shortcuts.map { shortcut in
            PluginCommand(
                id: shortcut.commandID,
                keyCode: shortcut.keyCode,
                modifiers: Modifiers.controlOption,
                group: .apps,
                desc: "\(shortcut.kind.helpVerb) \(shortcut.name)"
            ) {
                switch shortcut.kind {
                case .open:  open(shortcut, note: note)
                case .popup: togglePopup(shortcut, note: note)
                }
            }
        }
    }

    static func makeShortcut(from url: URL, keyCode: UInt32,
                             kind: AppShortcutKind = .open) -> AppShortcut {
        let bundle = Bundle(url: url)
        let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return AppShortcut(
            name: name,
            path: url.path,
            bundleIdentifier: bundle?.bundleIdentifier,
            keyCode: keyCode,
            kind: kind
        )
    }

    /// Visible means at least one window is on screen and the app is not hidden.
    private static func isShowing(_ app: NSRunningApplication) -> Bool {
        guard !app.isHidden else { return false }
        let windows = WindowFocus.windows(pid: app.processIdentifier)
        if windows.isEmpty { return app.isActive }
        return windows.contains { !$0.minimized }
    }

    private static func hide(_ app: NSRunningApplication) {
        let windows = WindowFocus.windows(pid: app.processIdentifier)
        let visible = windows.filter { !$0.minimized }
        let pid = app.processIdentifier
        if visible.isEmpty {
            app.hide()
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for window in visible {
                WindowFocus.minimize(pid: pid, id: window.id)
            }
        }
    }

    private static func show(_ app: NSRunningApplication) {
        app.unhide()
        let pid = app.processIdentifier
        let windows = WindowFocus.windows(pid: pid)
        let minimized = windows.filter(\.minimized)
        if minimized.isEmpty {
            app.activate()
            if let first = windows.first {
                WindowFocus.focus(pid: pid, id: first.id)
            }
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            for window in minimized {
                WindowFocus.unminimize(pid: pid, id: window.id)
            }
            DispatchQueue.main.async {
                app.activate()
                if let first = windows.first {
                    WindowFocus.focus(pid: pid, id: first.id)
                }
            }
        }
    }

    /// A freshly launched app often has no AX windows for a few hundred ms.
    private static func waitForWindows(pid: pid_t, attempts: Int, then: @escaping () -> Void) {
        if !WindowFocus.windows(pid: pid).isEmpty || attempts <= 0 {
            then()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            waitForWindows(pid: pid, attempts: attempts - 1, then: then)
        }
    }

    private static func runningApp(for shortcut: AppShortcut) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        if let bundleID = shortcut.bundleIdentifier, !bundleID.isEmpty {
            if let match = running.first(where: { $0.bundleIdentifier == bundleID }) {
                return match
            }
        }
        let path = URL(fileURLWithPath: shortcut.path).resolvingSymlinksInPath()
        return running.first { app in
            guard let url = app.bundleURL else { return false }
            return url.resolvingSymlinksInPath() == path
        }
    }

    private static func applicationURL(for shortcut: AppShortcut) -> URL? {
        if let bundleID = shortcut.bundleIdentifier, !bundleID.isEmpty,
           let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return url
        }
        let url = URL(fileURLWithPath: shortcut.path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
