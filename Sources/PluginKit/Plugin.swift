import AppKit
import CoreGraphics
import SwiftUI

/// The palette roles a plugin may ask for.
///
/// A deliberately small subset of the app's own roles: enough to paint a panel
/// that belongs with the bars, without a plugin needing to know the full theme
/// vocabulary or what a bar segment is.
public enum PluginColorRole: String, Sendable, CaseIterable {
    case background, surface, text, muted, accent, good, warn, danger, separator
}

/// The active palette, as an object plugin views can observe.
///
/// A plain closure would resolve correctly but never re-render: a plugin window
/// is built once, so switching palette in Settings would only show up the next
/// time it opened. Observing this means the change lands immediately, the same
/// as it does for the bars.
@MainActor
public final class PluginPalette: ObservableObject {

    private let resolve: (PluginColorRole) -> NSColor

    public init(resolve: @escaping (PluginColorRole) -> NSColor) {
        self.resolve = resolve
    }

    public func nsColor(_ role: PluginColorRole) -> NSColor { resolve(role) }

    public func color(_ role: PluginColorRole) -> Color { Color(nsColor: resolve(role)) }

    /// Called by the host when the user's palette changes.
    public func refresh() { objectWillChange.send() }
}

/// PluginKit is the contract between Spaceman's core and its optional add-ons.
///
/// A plugin is one removable feature. It may contribute keyboard commands (a
/// popup panel, usually), background services, or any mix — declaring only the
/// capabilities it has. Because commands come from here, the hotkey table is
/// derived from whatever is compiled in: exclude a plugin and its keys simply
/// don't exist.
///
/// Selection happens at build time. Each plugin is its own SwiftPM target under
/// `Plugins/<name>/`, depending only on PluginKit — which structurally enforces
/// the Go version's "no plugin may import another plugin" rule. Package.swift
/// assembles the target list from `SPACEMAN_PLUGINS` / `SPACEMAN_WITHOUT` /
/// `SPACEMAN_CORE_ONLY`, and the app reaches whatever was built through
/// `#if canImport(...)` in `PluginManifest.swift`. A plugin that isn't selected
/// isn't compiled at all.
///
/// This target deliberately knows nothing about AppKit, so the contract stays
/// testable and plugin logic that doesn't need UI stays in Swift 6 mode.

/// A cheat-sheet section. Mirrors the Go version's groups; the declaration
/// order is the order sections appear in the sheet, so grouping is a typed
/// choice rather than a string that has to match elsewhere exactly.
public enum CommandGroup: String, CaseIterable, Sendable {
    case focus, windows, layout, apps

    public var title: String {
        switch self {
        case .focus:   return "Focus"
        case .windows: return "Windows"
        case .layout:  return "Layout"
        case .apps:    return "Apps & panels"
        }
    }
}

/// A global keybinding a plugin contributes.
public struct PluginCommand {
    /// Stable name used to refer to the command (config remapping, logs),
    /// e.g. "launcher.toggle".
    public let id: String
    /// Carbon key code and modifier flags, as `HotkeyManager.register` takes.
    public let keyCode: UInt32
    public let modifiers: UInt32
    /// How the command reads in the cheat sheet. An empty `desc` binds the key
    /// but leaves it undocumented.
    public let group: CommandGroup
    public let desc: String
    public let action: @MainActor () -> Void

    public init(id: String, keyCode: UInt32, modifiers: UInt32,
                group: CommandGroup, desc: String,
                action: @escaping @MainActor () -> Void) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.group = group
        self.desc = desc
        self.action = action
    }
}

/// A piece of bar content a plugin contributes.
///
/// The core's own modules are named without a prefix (`clock`); a plugin's are
/// namespaced by convention (`clipboard.history`). The identifier is what a
/// saved bar preset stores, so it must stay stable across versions — and because
/// presets reference it by name, a preset survives the plugin being compiled
/// out: the bar simply renders nothing for a module it cannot find.
public struct PluginBarModule {
    /// Namespaced, e.g. `clipboard.history`.
    public let id: String
    /// How it reads in the bar editor's module picker.
    public let title: String
    public let summary: String
    /// The content itself. Sized to fit the bar, so it should be a compact row —
    /// the enclosing section supplies colour and padding.
    public let content: @MainActor () -> AnyView

    public init(id: String, title: String, summary: String,
                @ViewBuilder content: @escaping @MainActor () -> some View) {
        self.id = id
        self.title = title
        self.summary = summary
        self.content = { AnyView(content()) }
    }
}

/// How a scene's window is dressed.
public enum PluginSceneStyle: Sendable {
    /// A standard titled, resizable window. Right for anything document-shaped
    /// — several columns, a lot of content, something you leave open.
    case window
    /// A chrome-less floating panel: no title bar, rounded, dragged by its
    /// background, dismissed with Escape, and above ordinary windows.
    ///
    /// Right for something small and glanceable. A title bar on a panel that
    /// exists to show one number is most of its height spent on nothing.
    case panel
}

/// A window a plugin owns.
///
/// Declaring a scene is all that is needed: the app builds the window and
/// reopens the same one rather than stacking duplicates. A plugin that is only a
/// bar module declares none, and one that is only a window declares no bar
/// modules — which is what makes "app, status bar, or both" a matter of what you
/// fill in rather than which protocol you adopt.
public struct PluginScene {
    public let id: String
    /// The window's title. Unused by `.panel`, which has nowhere to show it.
    public let title: String
    public let style: PluginSceneStyle
    public let defaultSize: CGSize
    public let minSize: CGSize
    public let content: @MainActor () -> AnyView

    public init(id: String,
                title: String,
                style: PluginSceneStyle = .window,
                defaultSize: CGSize = CGSize(width: 820, height: 560),
                minSize: CGSize = CGSize(width: 560, height: 380),
                @ViewBuilder content: @escaping @MainActor () -> some View) {
        self.id = id
        self.title = title
        self.style = style
        self.defaultSize = defaultSize
        self.minSize = minSize
        self.content = { AnyView(content()) }
    }
}

/// A plugin's own pane in the Settings window.
///
/// Plugins keep their settings where the user already looks for settings, rather
/// than each inventing a config file. What the pane writes is the plugin's
/// business — `UserDefaults` under its own key prefix is the expected choice.
public struct PluginSettings {
    public let content: @MainActor () -> AnyView

    public init(@ViewBuilder content: @escaping @MainActor () -> some View) {
        self.content = { AnyView(content()) }
    }
}

/// What a plugin produced: whichever capabilities it actually has. Every field
/// is optional — a bar module returns just `barModules`, a panel just a scene
/// and the command that opens it, a background service just start/stop.
public struct PluginInstance {
    /// Global keybindings (typically one, to open a scene).
    public var commands: [PluginCommand] = []
    /// Bar content this plugin offers. Available in the bar editor whether or
    /// not any preset currently uses it.
    public var barModules: [PluginBarModule] = []
    /// Windows this plugin owns.
    public var scenes: [PluginScene] = []
    /// This plugin's pane in Settings ▸ Plugins. Plugins with nothing to
    /// configure simply don't appear there.
    public var settings: PluginSettings?
    /// Background work, e.g. a poller. `start` runs once everything is wired;
    /// `stop` on shutdown.
    public var start: (@MainActor () -> Void)?
    public var stop: (@MainActor () -> Void)?

    public init(commands: [PluginCommand] = [],
                barModules: [PluginBarModule] = [],
                scenes: [PluginScene] = [],
                settings: PluginSettings? = nil,
                start: (@MainActor () -> Void)? = nil,
                stop: (@MainActor () -> Void)? = nil) {
        self.commands = commands
        self.barModules = barModules
        self.scenes = scenes
        self.settings = settings
        self.start = start
        self.stop = stop
    }
}

/// A window offered to plugins, e.g. for a switcher list. Titles are resolved
/// through the Accessibility API by the app, so seeing one here implies no
/// permission beyond the one the tiler already needs.
public struct PluginWindow: Equatable, Sendable {
    public let id: CGWindowID
    public let title: String
    public let appName: String

    public init(id: CGWindowID, title: String, appName: String) {
        self.id = id
        self.title = title
        self.appName = appName
    }
}

/// A tiled window and the frame the layout intends for it.
///
/// The *planned* frame, not the live one, so a window still gliding into place
/// is reported where it will land — an overlay drawn on a mid-animation frame
/// would sit visibly off its window.
public struct PluginTiledWindow: Sendable, Equatable {
    public let id: CGWindowID
    public let title: String
    public let appName: String
    public let frame: CGRect

    public init(id: CGWindowID, title: String, appName: String, frame: CGRect) {
        self.id = id
        self.title = title
        self.appName = appName
        self.frame = frame
    }
}

/// What a swap-style plugin needs to draw itself: the focused window, and
/// everything it could trade places with.
public struct PluginSwapState: Sendable {
    public let focused: CGWindowID?
    /// Windows sharing the focused window's tiling region — one display, one
    /// Space. Slots are only comparable within a region, so this is exactly the
    /// set a swap may choose from.
    public let candidates: [PluginTiledWindow]

    public init(focused: CGWindowID?, candidates: [PluginTiledWindow]) {
        self.focused = focused
        self.candidates = candidates
    }
}

/// A spatial direction, for plugins that navigate the layout.
public enum PluginDirection: Sendable {
    case left, right, up, down
}

/// A window-manager action the core offers to plugins, e.g. "Re-tile windows"
/// for a command palette.
public struct PluginAction {
    public let title: String
    public let action: @MainActor () -> Void

    public init(title: String, action: @escaping @MainActor () -> Void) {
        self.title = title
        self.action = action
    }
}

/// Everything a plugin may need from the core, passed to `setup`. A protocol
/// rather than a concrete bag so the app can back it with live controllers
/// while tests substitute a stub.
@MainActor
public protocol PluginHost: AnyObject {
    /// Windows on the current Space, for switcher-style plugins.
    var windows: [PluginWindow] { get }
    /// Raise a window and activate its app.
    func focusWindow(_ id: CGWindowID)
    /// Window-manager actions a palette may offer, e.g. re-tile.
    var wmActions: [PluginAction] { get }

    /// The focused tiled window and everything it can trade slots with.
    func swapState() -> PluginSwapState

    /// The tiled window nearest `id` in `direction`, by the same rule the core's
    /// own focus movement uses — so a plugin's arrows agree with ⌃⌥ arrows
    /// rather than inventing a second idea of "the window to the left".
    func tiledNeighbor(of id: CGWindowID, direction: PluginDirection) -> CGWindowID?

    /// Exchange two windows' tiled slots. Persists through re-tiling.
    func swapWindows(_ a: CGWindowID, _ b: CGWindowID)
    /// Show a transient notice in the bottom bar.
    func note(_ message: String)

    /// Open one of this plugin's declared scenes, creating its window on first
    /// use and bringing the existing one forward after that.
    func showScene(_ id: String)

    /// Open the scene, or close it if it is already frontmost. The right
    /// behaviour for a chord that summons a panel: the same keys should put it
    /// away again.
    func toggleScene(_ id: String)

    /// A colour from the user's active palette.
    ///
    /// Plugins ask for roles rather than picking their own colours, so a panel
    /// follows whatever palette is selected in Settings instead of being the one
    /// surface that ignores it.
    func color(_ role: PluginColorRole) -> NSColor

    /// The same palette as an observable object, for SwiftUI plugin views that
    /// should repaint when the user switches palette.
    var palette: PluginPalette { get }

    /// A directory this plugin owns, under Application Support, created on
    /// demand. One per plugin rather than a shared folder, so uninstalling a
    /// plugin means deleting a directory and a plugin can never tread on
    /// another's files.
    func dataDirectory(for pluginName: String) -> URL
}

/// A registered add-on. `setup` builds it against the host and reports what it
/// contributes.
public protocol SpacemanPlugin {
    /// The plugin's identity: how it's referred to in logs and build flags.
    /// Required, unique.
    static var name: String { get }
    /// How it reads in Settings ▸ Plugins — the title, and a line saying what
    /// the plugin is for.
    ///
    /// Required rather than optional because *every* plugin gets a settings
    /// pane, whether or not it has anything to configure. A plugin the user
    /// cannot find in Settings is one they cannot tell is installed.
    static var displayName: String { get }
    static var summary: String { get }

    @MainActor static func setup(host: any PluginHost) -> PluginInstance
}

public extension SpacemanPlugin {
    /// Falls back to the identity, so a plugin only spells this out when the
    /// two genuinely differ.
    static var displayName: String { name.capitalized }
}

/// A plugin that set up successfully, paired with what it contributed.
public struct LoadedPlugin {
    public let name: String
    public let displayName: String
    public let summary: String
    public let instance: PluginInstance

    public init(name: String, displayName: String, summary: String,
                instance: PluginInstance) {
        self.name = name
        self.displayName = displayName
        self.summary = summary
        self.instance = instance
    }
}

@MainActor
public enum PluginManager {
    /// Builds every plugin in the manifest against `host`. The single place
    /// plugins come to life, so ordering and future error handling live here.
    public static func setupAll(_ plugins: [any SpacemanPlugin.Type],
                                host: any PluginHost) -> [LoadedPlugin] {
        plugins.map {
            LoadedPlugin(name: $0.name,
                         displayName: $0.displayName,
                         summary: $0.summary,
                         instance: $0.setup(host: host))
        }
    }
}
