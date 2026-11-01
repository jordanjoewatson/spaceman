import Testing
@testable import SpacemanCore

@Suite("Tiling exclusions")
struct TilingExclusionTests {

    private let editor = ExcludedApp(identifier: "com.example.editor", name: "Editor")

    @Test("an exact bundle ID matches, case-insensitively")
    func bundleID() {
        #expect(TilingExclusions.isExcluded([editor], bundleID: "com.example.editor", processName: "Editor"))
        #expect(TilingExclusions.isExcluded([editor], bundleID: "COM.Example.Editor", processName: nil))
        #expect(!TilingExclusions.isExcluded([editor], bundleID: "com.example.editor.helper", processName: nil))
    }

    @Test("an unbundled process matches by executable name")
    func processName() {
        let entry = ExcludedApp(identifier: "example-tool-arm64", name: "Tool")
        #expect(TilingExclusions.isExcluded([entry], bundleID: nil, processName: "example-tool-arm64"))
        #expect(!TilingExclusions.isExcluded([entry], bundleID: nil, processName: "example-tool-x86_64"))
    }

    @Test("a trailing star is a prefix match")
    func wildcard() {
        #expect(TilingExclusions.matches("example-tool-*", "example-tool-x86_64"))
        #expect(TilingExclusions.matches("com.example.*", "com.example.viewer"))
        #expect(!TilingExclusions.matches("example-tool-*", "example-other"))
    }

    @Test("empty and bare-star patterns match nothing")
    func degenerate() {
        #expect(!TilingExclusions.matches("", "anything"))
        #expect(!TilingExclusions.matches("*", "anything"))
        #expect(!TilingExclusions.isExcluded([editor], bundleID: nil, processName: nil))
    }

    @Test("defaults cover Apple utilities by prefix and no third-party apps")
    func appleDefaults() {
        let list = TilingExclusions.defaults
        #expect(list.allSatisfy { $0.identifier.hasPrefix("com.apple.") })
        #expect(TilingExclusions.isExcluded(list, bundleID: "com.apple.systempreferences", processName: nil))
        #expect(TilingExclusions.isExcluded(list, bundleID: "com.apple.systempreferences.GeneralSettings", processName: nil))
        #expect(TilingExclusions.isExcluded(list, bundleID: "com.apple.calculator", processName: "Calculator"))
        #expect(!TilingExclusions.isExcluded(list, bundleID: "com.apple.Safari", processName: "Safari"))
        #expect(!TilingExclusions.isExcluded(list, bundleID: "com.example.editor", processName: "Editor"))
    }

    @Test("a nested helper app is found inside the app the user installed")
    func nestedApps() {
        #expect(TilingExclusions.enclosingAppPaths(
            of: "/Applications/Outer.app/Contents/MacOS/Inner.app")
            == ["/Applications/Outer.app"])
        #expect(TilingExclusions.enclosingAppPaths(of: "/Applications/Safari.app").isEmpty)
        let outer = ExcludedApp(identifier: "com.example.outer", name: "Outer")
        #expect(TilingExclusions.isExcluded([outer],
            identities: ["com.example.inner", "com.example.outer", "Inner"]))
        #expect(!TilingExclusions.isExcluded([outer],
            identities: ["com.example.inner", "Inner"]))
    }

    @Test("the list round-trips and corrupt JSON degrades to empty")
    func coding() {
        let list = [editor, ExcludedApp(identifier: "example-tool-*", name: "Tool")]
        #expect(TilingExclusions.decode(TilingExclusions.encode(list)) == list)
        #expect(TilingExclusions.decode("not json").isEmpty)
        #expect(TilingExclusions.decode(Defaults.excludedApps.fallback) == TilingExclusions.defaults)
    }
}
