import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Displays")
struct DisplaysTests {

    private let main = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("a window on the display is kept")
    func onDisplay() {
        let window = CGRect(x: 8, y: 34, width: 779, height: 832)
        #expect(Displays.isOnDisplay(window, displays: [main]))
    }

    @Test("a window one Space to the right is rejected")
    func neighbouringSpaceRight() {
        // Observed shape: a window on the next Space over reports near x=2955
        // on a 1440pt display.
        let window = CGRect(x: 2955, y: 34, width: 779, height: 832)
        #expect(!Displays.isOnDisplay(window, displays: [main]))
    }

    @Test("a window one Space to the left is rejected")
    func neighbouringSpaceLeft() {
        let window = CGRect(x: -1702, y: 34, width: 779, height: 832)
        #expect(!Displays.isOnDisplay(window, displays: [main]))
    }

    @Test("a window dragged partly off the edge is still kept")
    func partiallyOffScreenIsKept() {
        // The centre is what matters: a user-dragged window hanging off the left
        // edge belongs to this Space and must keep its slot.
        let window = CGRect(x: -200, y: 100, width: 800, height: 600)
        #expect(Displays.isOnDisplay(window, displays: [main]))
    }

    @Test("a window on a second display is kept")
    func secondDisplay() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let window = CGRect(x: 1500, y: 100, width: 800, height: 600)
        #expect(Displays.isOnDisplay(window, displays: [main, secondary]))
    }

    @Test("no displays means nothing is on a display")
    func noDisplays() {
        #expect(!Displays.isOnDisplay(main, displays: []))
    }
}
