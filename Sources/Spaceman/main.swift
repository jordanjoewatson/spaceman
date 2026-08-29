import AppKit
import PluginKit
import SpacemanCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var state: BarState!
    private var bars: BarController!
    private var ledger: SpaceLedger!
    private var tiler: TilingController!
    private var hotkeys: HotkeyManager!
    private var statusItem: NSStatusItem!
    private var animationItem: NSMenuItem?
    private var autoFocusItem: NSMenuItem?
    private var mouseFocus: MouseFocus!
    private var commands: CommandStore!
    private var pluginHost: AppPluginHost!
    private var loadedPlugins: [LoadedPlugin] = []
    private let preferences = Preferences.shared
    private lazy var settingsWindow = SettingsWindowController(preferences: preferences)
    /// Every registered chord, in one table — the help sheet renders from this,
    /// so the two can never disagree.
    private var allCommands: [PluginCommand] = []
    private lazy var helpWindow = HelpWindowController(
        commands: { [weak self] in self?.allCommands ?? [] },
        scripts: { [weak self] in self?.commands.set.scripts ?? [] }
    )

    /// The cheat sheet is itself a command, so it appears on its own sheet.
    private var helpCommand: PluginCommand {
        PluginCommand(id: "help.toggle",
                      keyCode: KeyCode.h,
                      modifiers: Modifiers.controlOption,
                      group: .apps,
                      desc: "Show this shortcut list") { [weak self] in
            self?.helpWindow.toggle()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        enforceSingleInstance()

        state = BarState()
        state.startClock()

        ledger = SpaceLedger()

        bars = BarController(
            state: state,
            preferences: preferences,
            onCycleLayout: { [weak self] displayID in self?.tiler.cycleLayout(on: displayID) },
            onRetile:      { [weak self] in self?.tiler.tileNow() },
            onShrinkMaster:{ [weak self] in self?.tiler.adjustMaster(by: -0.05) },
            onGrowMaster:  { [weak self] in self?.tiler.adjustMaster(by: 0.05) }
        )

        tiler = TilingController(state: state, bars: bars, ledger: ledger,
                                 preferences: preferences)
        bars.onGeometryChange = { [weak self] in self?.tiler.tileNow() }

        // Layout settings changed anywhere — Settings window, `defaults write`,
        // an MDM profile — take effect on the next pass rather than the next
        // launch. `tileNow` is a no-op when nothing actually moved, so reacting
        // to every key is cheaper than working out which ones matter.
        preferences.observe { [weak self] in
            guard let self else { return }
            self.animationItem?.state = self.tiler.animationsEnabled ? .on : .off
            self.autoFocusItem?.state = self.preferences[Defaults.followMouse] ? .on : .off
            self.pluginHost?.paletteChanged()
            // Starts or stops the poller to match the preference, so the menu
            // item and `defaults write` drive the same path.
            self.mouseFocus?.sync()
            PopupApps.sync(self.preferences.appShortcuts)
            self.tiler.tileNow()
        }

        commands = CommandStore()
        commands.onChange = { [weak self] _ in self?.installStatusItem() }
        commands.onProblem = { [weak self] problem in self?.state.note(problem) }
        commands.load()
        commands.startWatching()

        // Plugins come up after the controllers they may need (tiler, bars)
        // and before hotkeys, so their commands bind in the same pass.
        pluginHost = AppPluginHost(tiler: tiler) { [weak self] message in
            self?.state.note(message)
        }
        loadedPlugins = PluginManager.setupAll(PluginManifest.plugins, host: pluginHost)
        // Register before the status item is built and before any bar renders,
        // so plugin scenes appear in the menu and plugin bar modules resolve on
        // the first pass rather than after something else forces a redraw.
        PluginSurface.shared.register(loadedPlugins)
        for plugin in loadedPlugins { plugin.instance.start?() }

        mouseFocus = MouseFocus(preferences: preferences) { [weak self] in
            self?.tiler.focusTargets() ?? []
        }
        mouseFocus.sync()

        PopupApps.sync(preferences.appShortcuts)
        installStatusItem()
        installHotkeys()

        tiler.start()
    }

    /// Stop a second copy from fighting the first over the same windows.
    ///
    /// Two running instances each reconcile the same Space against their own
    /// layout state and undo each other's moves every pass — windows judder,
    /// placements never settle, and it looks exactly like a tiling bug.
    /// `open` refuses to launch a duplicate, but running the executable
    /// directly (which is what iterating on a build looks like) bypasses
    /// LaunchServices entirely, so this has to be enforced in-process.
    ///
    /// The newest instance wins: during development the copy just launched is
    /// the one wanted.
    private func enforceSingleInstance() {
        let mine = ProcessInfo.processInfo.processIdentifier
        let myExecutable = Bundle.main.executableURL?.resolvingSymlinksInPath()

        let others = NSWorkspace.shared.runningApplications.filter { app in
            guard app.processIdentifier != mine else { return false }
            if let id = Bundle.main.bundleIdentifier, app.bundleIdentifier == id { return true }
            // Direct executable launches may not carry a bundle identifier.
            guard let mine = myExecutable,
                  let theirs = app.executableURL?.resolvingSymlinksInPath() else { return false }
            return mine == theirs
        }

        guard !others.isEmpty else { return }
        Log.debug("terminating \(others.count) older instance(s) of Spaceman")
        for app in others where !app.terminate() {
            app.forceTerminate()
        }
    }

    // MARK: - Menu bar item

    /// Create the status item once and rebuild only its menu. Creating a new
    /// `NSStatusItem` per call leaks one into the menu bar every time
    /// `commands.json` is saved (`commands.onChange` re-invokes this).
    private func installStatusItem() {
        if statusItem == nil {
            statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            statusItem.button?.image = BrandIcon.statusItemImage()
                ?? NSImage(systemSymbolName: "rectangle.split.3x1",
                           accessibilityDescription: "Spaceman")
        }

        // No key equivalents anywhere in this menu. A status-item menu's
        // equivalents only fire while the menu is already open, which reads as
        // a global shortcut that doesn't work — the real ones are registered
        // through `HotkeyManager` and shown in the tooltips below.
        let menu = NSMenu()
        menu.addItem(withTitle: "Re-tile", action: #selector(retile), keyEquivalent: "")
        menu.addItem(withTitle: "Cycle layout", action: #selector(cycleLayout), keyEquivalent: "")
        menu.addItem(.separator())

        for mode in LayoutMode.allCases {
            let item = NSMenuItem(title: mode.shortName.capitalized,
                                  action: #selector(pickLayout(_:)),
                                  keyEquivalent: "")
            item.representedObject = mode.rawValue
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let anim = NSMenuItem(title: "Animations",
                              action: #selector(toggleAnimations),
                              keyEquivalent: "")
        anim.state = tiler.animationsEnabled ? .on : .off
        animationItem = anim
        menu.addItem(anim)

        let autoFocus = NSMenuItem(title: "Auto focus",
                                   action: #selector(toggleAutoFocus),
                                   keyEquivalent: "")
        autoFocus.state = preferences[Defaults.followMouse] ? .on : .off
        autoFocus.toolTip = "Focus the window under the pointer, without raising it"
        autoFocusItem = autoFocus
        menu.addItem(autoFocus)

        // Plugin windows are deliberately absent from this menu. They are opened
        // by their own shortcut, listed on the ⌃⌥H sheet; putting them here
        // makes a window-manager menu into an app launcher.
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings),
                     keyEquivalent: "")

        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Spaceman", action: #selector(NSApplication.terminate(_:)),
                     keyEquivalent: "")
        statusItem.menu = menu
    }

    @objc private func retile() { tiler.tileNow() }

    @objc private func toggleAnimations() {
        tiler.animationsEnabled.toggle()
        animationItem?.state = tiler.animationsEnabled ? .on : .off
    }

    @objc private func toggleAutoFocus() {
        mouseFocus.isEnabled.toggle()
        autoFocusItem?.state = mouseFocus.isEnabled ? .on : .off
    }

    @objc private func showSettings() {
        settingsWindow.show()
    }

    @objc private func openPluginScene(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        PluginSurface.shared.showScene(id)
    }
    @objc private func cycleLayout() { tiler.cycleLayout() }

    @objc private func pickLayout(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LayoutMode(rawValue: raw) else { return }
        tiler.setLayout(mode)
    }

    // MARK: - Hotkeys

    private func installHotkeys() {
        hotkeys = HotkeyManager()

        // Core first, then whatever the build's plugins contribute — one table,
        // which is also what the help sheet renders from.
        allCommands = CommandCatalog.core(tiler: tiler)
            + [helpCommand]
            + loadedPlugins.flatMap(\.instance.commands)
            + AppLauncher.commands(preferences.appShortcuts) { [weak self] message in
                self?.state.note(message)
            }
        // Published before registration so the Shortcuts pane can see every
        // command's built-in key, which is what lets it reject a duplicate.
        ShortcutBindings.registered = allCommands

        // A user override replaces the built-in key. Applied here rather than in
        // the catalog so the declared default stays visible in Settings.
        let bindings = preferences.shortcuts
        allCommands = allCommands.map { command in
            let key = bindings.keyCode(for: command)
            guard key != command.keyCode else { return command }
            return PluginCommand(id: command.id,
                                 keyCode: key,
                                 modifiers: command.modifiers,
                                 group: command.group,
                                 desc: command.desc,
                                 action: command.action)
        }

        // Two commands claiming one chord is a build mistake, not an
        // environment one, and it fails silently — the first registration wins
        // and the second command simply never fires. Naming both is the only
        // way that becomes findable.
        var claimed: [String: String] = [:]
        var conflicts: [String] = []
        for command in allCommands {
            let chord = ChordGlyphs.string(keyCode: command.keyCode,
                                           modifiers: command.modifiers)
            if let owner = claimed[chord] {
                conflicts.append("\(chord): \(owner) and \(command.id)")
            } else {
                claimed[chord] = command.id
            }
        }
        if !conflicts.isEmpty {
            state.note("Conflicting shortcuts — \(conflicts.joined(separator: ", "))")
            Log.debug("shortcut conflicts: \(conflicts.joined(separator: ", "))")
        }

        var taken: [String] = []
        for command in allCommands {
            let action = command.action
            let registered = hotkeys.register(keyCode: command.keyCode,
                                              modifiers: command.modifiers,
                                              handler: { MainActor.assumeIsolated { action() } })
            if !registered {
                let chord = ChordGlyphs.string(keyCode: command.keyCode,
                                               modifiers: command.modifiers)
                taken.append("\(chord) (\(command.desc.isEmpty ? command.id : command.desc))")
            }
        }

        if !taken.isEmpty {
            // Another app owns the combination. Not fatal — the menu and the
            // bottom bar still drive everything.
            state.note("Shortcut(s) unavailable: \(taken.joined(separator: ", "))")
        }
    }

    // MARK: - URL scheme

    /// `spaceman://` is how other apps drive this one.
    ///
    /// A URL scheme is a clean way to accept commands from outside: it is
    /// declarative, it carries no code, and it works from Shortcuts,
    /// AppleScript, Terminal (`open spaceman://…`) or any launcher — without
    /// the app needing to execute anything the user supplied.
    ///
    ///     spaceman://run/coding          run a named command from commands.json
    ///     spaceman://layout/bsp          run a single built-in verb
    ///     spaceman://retile
    ///     spaceman://master/0.65
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    private func handle(_ url: URL) {
        guard url.scheme?.lowercased() == "spaceman" else { return }

        // spaceman://verb/argument  ->  host = verb, path = /argument
        let verb = (url.host ?? "").lowercased()
        let argument = url.pathComponents.filter { $0 != "/" }.first

        if verb == "run" {
            guard let name = argument, let script = commands.set.script(named: name) else {
                state.note("no custom command named '\(argument ?? "")'")
                return
            }
            tiler.run(script)
            return
        }

        // Anything else is a single built-in verb, parsed by the same grammar
        // the config file uses so the two can never drift apart.
        let text = argument.map { "\(verb) \($0)" } ?? verb
        do {
            tiler.run(try Command.parse(text))
        } catch {
            state.note("\(url.absoluteString): \(error)")
        }
    }

}

// Top-level code is nonisolated, but every type below is main-actor bound.
// AppKit only ever runs this on the main thread, so asserting that is accurate
// rather than a workaround.
MainActor.assumeIsolated {
    // `-plugins` lists what this binary carries and exits — a build check, not
    // an app launch. Plugins are chosen at build time (see Package.swift), so
    // this is the only way to ask a built binary what it contains.
    if CommandLine.arguments.contains("-plugins") {
        for plugin in PluginManifest.plugins { print(plugin.name) }
        exit(0)
    }

    let app = NSApplication.shared
    // `NSApplication.delegate` is weak; this local owns it for the lifetime of
    // `run()`, which never returns until the app quits.
    let delegate = AppDelegate()
    app.delegate = delegate
    // Agent app: no Dock tile, no app-switcher entry. Matches LSUIElement in the
    // Info.plist so it behaves the same when run from the command line.
    app.setActivationPolicy(.accessory)
    app.run()
}
