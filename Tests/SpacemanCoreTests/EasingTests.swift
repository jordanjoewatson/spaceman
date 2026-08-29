import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Easing")
struct EasingTests {

    @Test("the curve is pinned at both ends")
    func endpoints() {
        #expect(Easing.easeOutCubic(0) == 0)
        #expect(Easing.easeOutCubic(1) == 1)
    }

    @Test("out-of-range progress is clamped, never extrapolated")
    func clamping() {
        // A dropped frame can hand us t > 1. Extrapolating would fling the
        // window past its target and snap back.
        #expect(Easing.easeOutCubic(-0.5) == 0)
        #expect(Easing.easeOutCubic(1.7) == 1)
    }

    @Test("the curve is monotonic, so a window never reverses direction")
    func monotonic() {
        var previous = Easing.easeOutCubic(0)
        for step in 1...100 {
            let value = Easing.easeOutCubic(CGFloat(step) / 100)
            #expect(value >= previous)
            previous = value
        }
    }

    @Test("most of the distance is covered early")
    func frontLoaded() {
        // The point of easeOut here: the window should look like it arrives
        // quickly and settles, not like it drifts.
        #expect(Easing.easeOutCubic(0.33) > 0.6)
    }
}

@Suite("Frame interpolation")
struct InterpolationTests {

    private let from = CGRect(x: 0, y: 0, width: 100, height: 100)
    private let to = CGRect(x: 200, y: 100, width: 400, height: 300)

    @Test("progress 0 and 1 are exactly the endpoints")
    func endpoints() {
        #expect(from.interpolated(to: to, progress: 0) == from)
        #expect(from.interpolated(to: to, progress: 1) == to)
    }

    @Test("the midpoint is halfway on every edge")
    func midpoint() {
        let mid = from.interpolated(to: to, progress: 0.5)
        #expect(mid == CGRect(x: 100, y: 50, width: 250, height: 200))
    }

    @Test("intermediate frames are always valid window rects")
    func alwaysValid() {
        // Every intermediate rect is handed straight to the window server, so a
        // negative width at any point would be a real failure.
        for step in 0...20 {
            let rect = from.interpolated(to: to, progress: CGFloat(step) / 20)
            #expect(rect.width > 0)
            #expect(rect.height > 0)
        }
    }

    @Test("out-of-range progress is clamped")
    func clamped() {
        #expect(from.interpolated(to: to, progress: 2.0) == to)
        #expect(from.interpolated(to: to, progress: -1.0) == from)
    }

    @Test("shrinking interpolates as cleanly as growing")
    func shrinking() {
        let mid = to.interpolated(to: from, progress: 0.5)
        #expect(mid == CGRect(x: 100, y: 50, width: 250, height: 200))
    }
}
