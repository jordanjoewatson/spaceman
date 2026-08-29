import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("EdgeReveal")
struct EdgeRevealTests {

    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)

    private func point(y: CGFloat) -> CGPoint { CGPoint(x: 720, y: y) }

    @Test("both bars start visible")
    func startsVisible() {
        let reveal = EdgeReveal()
        #expect(!reveal.topHidden)
        #expect(!reveal.bottomHidden)
    }

    @Test("pointer at the bottom edge hides only the bottom bar")
    func bottomEdgeHidesBottom() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 1), screen: screen)
        #expect(reveal.bottomHidden)
        #expect(!reveal.topHidden)
    }

    @Test("pointer at the top edge hides only the top bar")
    func topEdgeHidesTop() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 899), screen: screen)
        #expect(reveal.topHidden)
        #expect(!reveal.bottomHidden)
    }

    @Test("the middle of the screen hides nothing")
    func middleHidesNothing() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 450), screen: screen)
        #expect(!reveal.topHidden)
        #expect(!reveal.bottomHidden)
    }

    @Test("both edges can never be hidden at once on a normal display")
    func edgesAreMutuallyExclusive() {
        var reveal = EdgeReveal()
        for y in stride(from: CGFloat(0), through: 900, by: 10) {
            reveal.update(pointer: point(y: y), screen: screen)
            #expect(!(reveal.topHidden && reveal.bottomHidden),
                    "a 900pt screen is far wider than both zones combined")
        }
    }

    @Test("the top edge hysteresis behaves like the bottom's")
    func topEdgeHysteresis() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 899), screen: screen)
        #expect(reveal.topHidden)

        reveal.update(pointer: point(y: 880), screen: screen)
        #expect(reveal.topHidden, "still inside the exit zone")

        reveal.update(pointer: point(y: 800), screen: screen)
        #expect(!reveal.topHidden, "clear of the exit zone")
    }

    @Test("the bar stays hidden inside the exit zone")
    func hysteresisHoldsHidden() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 1), screen: screen)
        #expect(reveal.bottomHidden)

        // Just outside the enter zone but inside the exit zone: still hidden.
        reveal.update(pointer: point(y: 20), screen: screen)
        #expect(reveal.bottomHidden, "should not reappear the instant the pointer moves 1pt")
    }

    @Test("the bar returns once the pointer clears the exit zone")
    func hysteresisReleases() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 1), screen: screen)
        reveal.update(pointer: point(y: 100), screen: screen)
        #expect(!reveal.bottomHidden)
    }

    @Test("a pointer resting on the boundary does not flap")
    func noFlappingAtBoundary() {
        // The reason hysteresis exists: at 30 Hz, a single-threshold design
        // toggles the bar dozens of times a second while the pointer sits still.
        var reveal = EdgeReveal()
        let boundary = screen.minY + EdgeReveal.enterZone

        reveal.update(pointer: point(y: boundary), screen: screen)
        #expect(reveal.bottomHidden)

        for _ in 0..<10 {
            let changed = reveal.update(pointer: point(y: boundary), screen: screen)
            #expect(changed == false, "state must be stable while the pointer is stationary")
        }
    }

    @Test("update reports whether anything changed")
    func reportsChange() {
        var reveal = EdgeReveal()
        // Bound outside #expect: the macro captures its argument immutably.
        let first = reveal.update(pointer: point(y: 1), screen: screen)
        #expect(first)
        let second = reveal.update(pointer: point(y: 1), screen: screen)
        #expect(!second)
    }

    @Test("a pointer on another display restores both bars")
    func pointerOffScreenRestores() {
        var reveal = EdgeReveal()
        reveal.update(pointer: point(y: 1), screen: screen)
        #expect(reveal.bottomHidden)

        // Moving onto a second display must not leave this one's bar stuck off.
        reveal.update(pointer: CGPoint(x: 2000, y: 400), screen: screen)
        #expect(!reveal.bottomHidden)
        #expect(!reveal.topHidden)
    }
}
