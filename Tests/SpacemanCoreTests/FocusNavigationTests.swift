import CoreGraphics
import Testing
@testable import SpacemanCore

@Suite("FocusNavigation")
struct FocusNavigationTests {

    // A 2×2 grid in AppKit coordinates (y up): 1 top-left, 2 top-right,
    // 3 bottom-left, 4 bottom-right.
    private let rects: [CGWindowID: CGRect] = [
        1: CGRect(x: 0, y: 100, width: 100, height: 100),
        2: CGRect(x: 100, y: 100, width: 100, height: 100),
        3: CGRect(x: 0, y: 0, width: 100, height: 100),
        4: CGRect(x: 100, y: 0, width: 100, height: 100),
    ]

    @Test("neighbours in each direction", arguments: [
        (CGWindowID(1), FocusDirection.right, CGWindowID(2)),
        (CGWindowID(1), .down, CGWindowID(3)),
        (CGWindowID(3), .up, CGWindowID(1)),
        (CGWindowID(3), .right, CGWindowID(4)),
        (CGWindowID(2), .left, CGWindowID(1)),
        (CGWindowID(2), .down, CGWindowID(4)),
    ])
    func neighbors(from: CGWindowID, direction: FocusDirection, want: CGWindowID) {
        #expect(FocusNavigation.neighbor(of: from, in: rects, direction: direction) == want)
    }

    @Test("nothing at the layout edge", arguments: [
        (CGWindowID(1), FocusDirection.left),
        (CGWindowID(1), .up),
        (CGWindowID(4), .right),
        (CGWindowID(4), .down),
    ])
    func edge(from: CGWindowID, direction: FocusDirection) {
        #expect(FocusNavigation.neighbor(of: from, in: rects, direction: direction) == nil)
    }

    @Test("an unknown window has no neighbours")
    func unknownWindow() {
        #expect(FocusNavigation.neighbor(of: 99, in: rects, direction: .right) == nil)
    }

    @Test("nearest along the primary axis wins over cross-axis drift")
    func crossAxisPenalty() {
        let current = CGRect(x: 0, y: 0, width: 100, height: 100)
        // Directly right beats further right-and-higher, even when the higher
        // one is horizontally nearer.
        let candidates: [CGWindowID: CGRect] = [
            1: current,
            2: CGRect(x: 300, y: 0, width: 100, height: 100),
            3: CGRect(x: 150, y: 200, width: 100, height: 100),
        ]
        #expect(FocusNavigation.neighbor(of: 1, in: candidates, direction: .right) == 2)
        // ...but looking up, the vertically aligned one is preferred.
        #expect(FocusNavigation.neighbor(of: 1, in: candidates, direction: .up) == 3)
    }

    @Test("equal candidates resolve deterministically")
    func tieBreak() {
        let candidates: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            5: CGRect(x: 200, y: 0, width: 100, height: 100),
            3: CGRect(x: 200, y: 0, width: 100, height: 100),
        ]
        #expect(FocusNavigation.neighbor(of: 1, in: candidates, direction: .right) == 3)
    }
}

@Suite("Zoomed frame")
struct CenteredTests {

    @Test("centered fraction of an area")
    func centered() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
        #expect(Layout.centered(in: area, fraction: 0.8)
                == CGRect(x: 100, y: 80, width: 800, height: 640))
    }

    @Test("centering respects the area's origin")
    func offsetArea() {
        let area = CGRect(x: 500, y: 200, width: 1000, height: 800)
        #expect(Layout.centered(in: area, fraction: 0.5)
                == CGRect(x: 750, y: 400, width: 500, height: 400))
    }
}
