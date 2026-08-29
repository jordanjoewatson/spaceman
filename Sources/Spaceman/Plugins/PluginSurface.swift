import AppKit
import SwiftUI
import PluginKit
import SpacemanCore

/// Everything the loaded plugins contribute to the app's own surfaces: bar
/// content and windows.
///
/// One place to look up "what does `clipboard.history` render as" and "which windows
/// exist", so neither the bar renderer nor the status menu has to know a plugin
/// list. Populated once after `PluginManager.setupAll`.
@MainActor
final class PluginSurface: ObservableObject {

    static let shared = PluginSurface()

    private(set) var barModules: [String: PluginBarModule] = [:]
    private(set) var scenes: [String: PluginScene] = [:]
    private var windows: [String: NSWindow] = [:]

    /// Descriptors for the bar editor's picker, in plugin load order after the
    /// core's own modules.
    private(set) var barDescriptors: [BarModuleDescriptor] = []

    /// One entry per loaded plugin — *every* plugin, not only the ones with
    /// something to configure.
    ///
    /// A plugin missing from Settings is one the user cannot tell is installed,
    /// so the pane is built here from what the plugin must declare, and the
    /// plugin's own controls are dropped in underneath when it has any.
    struct SettingsPane {
        let name: String
        let title: String
        let summary: String
        let shortcuts: [(chord: String, desc: String)]
        /// nil when the plugin has nothing to configure.
        let content: (@MainActor () -> AnyView)?
    }

    private(set) var settingsPanes: [SettingsPane] = []

    func register(_ plugins: [LoadedPlugin]) {
        for plugin in plugins {
            let shortcuts = plugin.instance.commands
                .filter { !$0.desc.isEmpty }
                .map { (ChordGlyphs.string(keyCode: $0.keyCode, modifiers: $0.modifiers),
                        $0.desc) }
            settingsPanes.append(SettingsPane(name: plugin.name,
                                              title: plugin.displayName,
                                              summary: plugin.summary,
                                              shortcuts: shortcuts,
                                              content: plugin.instance.settings?.content))
            for module in plugin.instance.barModules {
                barModules[module.id] = module
                barDescriptors.append(BarModuleDescriptor(BarModule(module.id),
                                                          module.title,
                                                          module.summary))
            }
            for scene in plugin.instance.scenes {
                scenes[scene.id] = scene
            }
        }
        objectWillChange.send()
    }

    /// A plugin module's content, or nil when no loaded plugin provides it.
    ///
    /// nil is a normal outcome, not an error: a preset may name a module from a
    /// plugin this build excludes, and the right response is to render nothing
    /// and leave the preset untouched, so re-adding the plugin restores it.
    func barContent(for module: BarModule) -> AnyView? {
        barModules[module.id]?.content()
    }

    /// Open a plugin's window, or bring it forward if already open.
    ///
    /// Windows are kept rather than rebuilt so a panel holds its scroll position
    /// and selection between openings — and, for anything backed by SwiftData,
    /// so it keeps one model context rather than accumulating them.
    func showScene(_ id: String) {
        guard let scene = scenes[id] else { return }

        let window = windows[id] ?? makeWindow(for: scene)
        windows[id] = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Close the window if it is already up front, open it otherwise.
    ///
    /// Only closes when it is *frontmost*: a panel that is open but buried
    /// behind other windows should come forward on the chord, not disappear.
    func toggleScene(_ id: String) {
        if let window = windows[id], window.isVisible, window.isKeyWindow {
            window.orderOut(nil)
            return
        }
        showScene(id)
    }

    private func makeWindow(for scene: PluginScene) -> NSWindow {
        let window: NSWindow
        switch scene.style {
        case .window:
            window = NSWindow(
                contentRect: CGRect(origin: .zero, size: scene.defaultSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = scene.title
            window.contentView = NSHostingView(rootView: scene.content())

        case .panel:
            window = PluginPanel(
                contentRect: CGRect(origin: .zero, size: scene.defaultSize),
                styleMask: [.borderless, .resizable, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            // No title bar to grab, so the whole surface drags.
            window.isMovableByWindowBackground = true
            // Above ordinary windows: a glanceable panel is worth nothing behind
            // the thing you are working in.
            window.level = .floating

            // The content paints the panel's background, so it has to be the
            // thing that gets rounded — a borderless window has no chrome of its
            // own to clip against.
            let hosting = NSHostingView(rootView: scene.content())
            hosting.wantsLayer = true
            hosting.layer?.cornerRadius = 12
            hosting.layer?.cornerCurve = .continuous
            hosting.layer?.masksToBounds = true
            window.contentView = hosting
        }

        window.contentMinSize = scene.minSize
        // Come to the user rather than dragging the user to the window.
        // Without this, activating a window that was left on another Space
        // switches Spaces to reach it — which is exactly what a summoned panel
        // must not do. `.moveToActiveSpace` brings it here instead.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        // Closing a plugin window must not deallocate it — `showScene` hands the
        // same window back next time.
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("SpacemanPlugin.\(scene.id)")
        window.center()
        return window
    }
}

/// A chrome-less plugin panel.
///
/// Borderless windows refuse key status by default, which would leave a panel
/// unable to take a keystroke — including the Escape that dismisses it.
private final class PluginPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Escape closes it. With no title bar there is no close button, so without
    /// this the only way out is the chord that opened it.
    override func cancelOperation(_ sender: Any?) {
        orderOut(nil)
    }
}
