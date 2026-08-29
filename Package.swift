// swift-tools-version:6.0
import Foundation
import PackageDescription

// MARK: - Plugin selection
//
// A plugin is one removable feature, selected at build time — the Swift
// counterpart of the Go version's link-time manifest (docs/plugins.md). Each
// plugin is its own target under `Plugins/<name>/` depending only on
// PluginKit, which structurally enforces the "no plugin imports another
// plugin" rule. A plugin you don't select is not a build target at all: not
// its code, not its keybinding. The app reaches whatever was built through
// `#if canImport(...)` in Sources/Spaceman/Plugins/PluginManifest.swift.
//
// Selection is driven by environment variables (build-app.sh maps
// --plugins/--without/--core-only onto these):
//
//   SPACEMAN_PLUGINS=launcher,clipboard only these
//   SPACEMAN_WITHOUT=launcher           everything except these
//   SPACEMAN_CORE_ONLY=1                no plugins at all
//
// Unset, every plugin is built, so a plain `swift build` — and `swift test` —
// always sees the full set.

// Every plugin, one per directory under Plugins/. Adding a plugin means one
// line here plus a `#if canImport` entry in PluginManifest.swift.
let knownPlugins: [(name: String, target: String)] = [
    ("launcher", "LauncherPlugin"),
    ("swap", "SwapPlugin"),
    ("pomodoro", "PomodoroPlugin"),
    ("clipboard", "ClipboardPlugin"),
]

func parseList(_ raw: String?) -> [String]? {
    guard let raw, !raw.isEmpty else { return nil }
    return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
}

let env = ProcessInfo.processInfo.environment
var selected = knownPlugins.map(\.name)
if let only = parseList(env["SPACEMAN_PLUGINS"]) { selected = only }
if let without = parseList(env["SPACEMAN_WITHOUT"]) {
    selected.removeAll { without.contains($0) }
}
if env["SPACEMAN_CORE_ONLY"] == "1" { selected = [] }

let knownNames = knownPlugins.map(\.name)
for name in selected where !knownNames.contains(name) {
    print("warning: unknown plugin '\(name)' — known plugins: \(knownNames.joined(separator: ", "))")
}
selected = selected.filter { knownNames.contains($0) }

// MARK: - Targets

var targets: [Target] = [
    // Pure geometry and model code. No AppKit, no system calls, so it runs
    // under `swift test` with no window server and stays in Swift 6 mode.
    .target(
        name: "SpacemanCore",
        swiftSettings: [.swiftLanguageMode(.v6)]
    ),
    // The plugin contract and helpers shared between plugins (e.g. the fuzzy
    // matcher).
    //
    // Language mode 5 because the contract carries SwiftUI views: a plugin may
    // contribute bar content or a whole window, and there is no way to express
    // that without the view types. Splitting a pure half out was considered and
    // rejected — `PluginInstance` would then be unable to name the very types
    // plugins contribute, and every plugin author would import two modules to
    // describe one plugin.
    .target(
        name: "PluginKit",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ),
]

// Plugin targets. AppKit and Carbon interop is full of non-Sendable types, so
// like the app they build in language mode 5.
for plugin in knownPlugins where selected.contains(plugin.name) {
    targets.append(.target(
        name: plugin.target,
        dependencies: ["PluginKit"],
        path: "Plugins/\(plugin.name)",
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}

// The app. AppKit and Carbon interop is full of non-Sendable types and C
// callbacks, so this target stays in language mode 5 — see README.
targets.append(.executableTarget(
    name: "Spaceman",
    dependencies: ["SpacemanCore", "PluginKit"]
        + knownPlugins.filter { selected.contains($0.name) }.map { .byName(name: $0.target) },
    swiftSettings: [.swiftLanguageMode(.v5)]
))

targets.append(.testTarget(
    name: "SpacemanCoreTests",
    dependencies: ["SpacemanCore"],
    swiftSettings: [.swiftLanguageMode(.v6)]
))
targets.append(.testTarget(
    name: "PluginKitTests",
    dependencies: ["PluginKit"],
    swiftSettings: [.swiftLanguageMode(.v5)]
))
// A plugin's test target exists only when it has tests. Declaring one for an
// empty directory makes SwiftPM warn on every build, which would mean a new
// plugin cannot be added without writing a test first.
for plugin in knownPlugins where selected.contains(plugin.name) {
    let path = "Tests/\(plugin.target)Tests"
    let hasTests = (try? FileManager.default.contentsOfDirectory(atPath: path))?
        .contains { $0.hasSuffix(".swift") } ?? false
    guard hasTests else { continue }

    targets.append(.testTarget(
        name: "\(plugin.target)Tests",
        dependencies: [.byName(name: plugin.target)],
        path: path,
        swiftSettings: [.swiftLanguageMode(.v5)]
    ))
}

let package = Package(
    name: "Spaceman",
    platforms: [.macOS(.v14)],
    targets: targets
)
