import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Window rules")
struct WindowRulesTests {

    @Test("a standard resizable window is tiled")
    func standardWindow() {
        #expect(WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXStandardWindow",
            isModal: false, resizable: true, movable: true))
    }

    @Test("dialogs, sheets and popovers are left alone")
    func overlaysRejected() {
        #expect(!WindowRules.isDocumentWindow(
            role: "AXSheet", subrole: "AXStandardWindow",
            isModal: false, resizable: true, movable: true))
        #expect(!WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXDialog",
            isModal: false, resizable: true, movable: true))
        #expect(!WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXFloatingWindow",
            isModal: false, resizable: true, movable: true))
        #expect(!WindowRules.isDocumentWindow(
            role: "AXPopover", subrole: "AXStandardWindow",
            isModal: false, resizable: true, movable: true))
    }

    @Test("modal, fixed-size and immovable windows are left alone")
    func flagsRejected() {
        #expect(!WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXStandardWindow",
            isModal: true, resizable: true, movable: true))
        #expect(!WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXStandardWindow",
            isModal: false, resizable: false, movable: true))
        #expect(!WindowRules.isDocumentWindow(
            role: "AXWindow", subrole: "AXStandardWindow",
            isModal: false, resizable: true, movable: false))
    }
}

@Suite("Space assignment")
struct SpaceAssignmentTests {

    private func window(frame: CGRect, spaces: Set<UInt64>) -> ManagedWindow {
        ManagedWindow(id: 1, pid: 1, ownerName: "Test", frame: frame,
                      zOrder: 0, spaceIDs: spaces)
    }

    @Test("a tagged window follows its Space, not its frame centre")
    func spaceWinsOverCentre() {
        let screenA = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let screenB = CGRect(x: 1440, y: 0, width: 1440, height: 900)
        // Centre sits on B, tag says Space 10 (display A).
        let window = window(frame: CGRect(x: 1500, y: 100, width: 400, height: 300),
                            spaces: [10])
        #expect(Displays.belongs(window, toSpace: 10, screen: screenA))
        #expect(!Displays.belongs(window, toSpace: 20, screen: screenB))
    }

    @Test("an untagged window falls back to frame centre")
    func untaggedUsesCentre() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let on = window(frame: CGRect(x: 100, y: 100, width: 400, height: 300), spaces: [])
        let off = window(frame: CGRect(x: 2000, y: 100, width: 400, height: 300), spaces: [])
        #expect(Displays.belongs(on, toSpace: 1, screen: screen))
        #expect(!Displays.belongs(off, toSpace: 1, screen: screen))
    }
}
