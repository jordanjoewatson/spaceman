import Testing
import Foundation
@testable import SpacemanCore

@Suite("App shortcuts")
struct AppShortcutTests {

    @Test("command ids are namespaced by kind")
    func commandID() {
        let open = AppShortcut(id: "abc", name: "Safari",
                               path: "/Applications/Safari.app", keyCode: 17)
        #expect(open.commandID == "apps.open.abc")
        let popup = AppShortcut(id: "abc", name: "Safari",
                                path: "/Applications/Safari.app", keyCode: 17, kind: .popup)
        #expect(popup.commandID == "apps.popup.abc")
    }

    @Test("a list saved before kinds still decodes as open")
    func missingKindDefaultsToOpen() {
        let json = """
        [{"id":"1","name":"Safari","path":"/Applications/Safari.app","keyCode":17}]
        """
        let decoded = AppShortcut.decodeList(json)
        #expect(decoded.count == 1)
        #expect(decoded[0].kind == .open)
        #expect(decoded[0].commandID == "apps.open.1")
    }

    @Test("an empty or corrupt list decodes as nothing")
    func decodeToleratesBadInput() {
        #expect(AppShortcut.decodeList("[]").isEmpty)
        #expect(AppShortcut.decodeList("not json").isEmpty)
        #expect(AppShortcut.decodeList("").isEmpty)
    }

    @Test("a well-formed list round-trips")
    func roundTrip() {
        let original = [
            AppShortcut(id: "1", name: "Safari", path: "/Applications/Safari.app",
                        bundleIdentifier: "com.apple.Safari", keyCode: 17),
            AppShortcut(id: "2", name: "Notes", path: "/System/Applications/Notes.app",
                        keyCode: 0, kind: .popup),
        ]
        let decoded = AppShortcut.decodeList(AppShortcut.encodeList(original))
        #expect(decoded == original)
    }

    @Test("T is the first suggested key")
    func prefersT() {
        #expect(AppShortcut.firstFreeKey(taken: []) == 17)
        #expect(AppShortcut.preferredKeyCodes.first == 17)
    }

    @Test("suggested key skips ones already taken")
    func skipsTaken() {
        #expect(AppShortcut.firstFreeKey(taken: [17]) == 0)
        let all = Set(AppShortcut.preferredKeyCodes)
        #expect(AppShortcut.firstFreeKey(taken: all) == nil)
    }
}
