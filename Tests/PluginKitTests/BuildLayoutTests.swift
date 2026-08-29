import Foundation
import Testing

/// The plugin manifest is build-system state, so a plugin that exists on disk
/// but was never listed is a feature that silently doesn't exist — the same
/// failure the Go version's `TestDefaultManifestListsEveryPlugin` guards. The
/// SwiftPM manifest sandbox can't read the package directory, so that check
/// lives here instead: every `Plugins/<name>/` directory must be listed both
/// in Package.swift's `knownPlugins` and in PluginManifest.swift.
@Suite("Build layout")
struct BuildLayoutTests {

    // …/swiftdev/Tests/PluginKitTests/BuildLayoutTests.swift -> …/swiftdev
    private let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private func pluginDirectories() -> [String] {
        let pluginsDir = packageRoot.appendingPathComponent("Plugins")
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: pluginsDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        return entries
            .filter {
                ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false)
                    && !$0.lastPathComponent.hasPrefix(".")
            }
            .map(\.lastPathComponent)
    }

    @Test("every plugin directory is listed in Package.swift")
    func pluginsListedInManifest() throws {
        let manifest = try String(contentsOf: packageRoot.appendingPathComponent("Package.swift"),
                                  encoding: .utf8)
        for name in pluginDirectories() {
            let target = name.prefix(1).uppercased() + name.dropFirst() + "Plugin"
            #expect(manifest.contains("\"\(name)\""),
                    "Plugins/\(name) is not in Package.swift's knownPlugins")
            #expect(manifest.contains("\"\(target)\""),
                    "Plugins/\(name): expected target name \(target) in knownPlugins")
        }
    }

    @Test("every plugin directory is registered in PluginManifest.swift")
    func pluginsRegisteredInApp() throws {
        let registration = try String(
            contentsOf: packageRoot.appendingPathComponent(
                "Sources/Spaceman/Plugins/PluginManifest.swift"),
            encoding: .utf8)
        for name in pluginDirectories() {
            let target = name.prefix(1).uppercased() + name.dropFirst() + "Plugin"
            #expect(registration.contains("canImport(\(target))"),
                    "Plugins/\(name) has no `#if canImport(\(target))` entry in PluginManifest.swift")
        }
    }
}
