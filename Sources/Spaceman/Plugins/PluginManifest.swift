import PluginKit

#if canImport(LauncherPlugin)
import LauncherPlugin
#endif

#if canImport(SwapPlugin)
import SwapPlugin
#endif

#if canImport(PomodoroPlugin)
import PomodoroPlugin
#endif

#if canImport(ClipboardPlugin)
import ClipboardPlugin
#endif

/// The build manifest: every plugin this binary carries, one entry per
/// selected plugin target. `canImport` is the Swift counterpart of the Go
/// version's blank-import list — Package.swift only declares the dependency
/// when the plugin is selected, so an excluded plugin's entry here compiles
/// away to nothing. (Built imperatively because `#if` can't appear inside an
/// array literal.)
///
/// Adding a plugin: one line in Package.swift's `knownPlugins`, one entry here.
enum PluginManifest {
    static let plugins: [any SpacemanPlugin.Type] = {
        var all: [any SpacemanPlugin.Type] = []
        #if canImport(LauncherPlugin)
        all.append(LauncherPlugin.self)
        #endif
        #if canImport(SwapPlugin)
        all.append(SwapPlugin.self)
        #endif
        #if canImport(PomodoroPlugin)
        all.append(PomodoroPlugin.self)
        #endif
        #if canImport(ClipboardPlugin)
        all.append(ClipboardPlugin.self)
        #endif
        return all
    }()
}
