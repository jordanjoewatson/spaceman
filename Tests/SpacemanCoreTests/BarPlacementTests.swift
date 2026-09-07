import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Bar placement")
struct BarPlacementTests {

    /// A 14-inch-class notched display: 38pt camera strip, no Dock.
    private let notchedFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    private let notchedVisible = CGRect(x: 0, y: 0, width: 1512, height: 944)
    private let safeTop: CGFloat = 38

    private let externalFrame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    private let externalVisible = CGRect(x: 0, y: 0, width: 1920, height: 1055)

    @Test("a flush top bar on an external display sits on the visible frame")
    func externalFlushTop() {
        let frame = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: externalVisible,
            thickness: 26,
            margin: 0)
        #expect(frame.maxY == externalVisible.maxY)
        #expect(frame.height == 26)
        #expect(frame.width == externalVisible.width)
        #expect(BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: externalVisible) == 26)
    }

    @Test("a flush top bar on a notched display starts just below the camera strip")
    func notchedFlushTopStartsBelowStrip() {
        let frame = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: notchedVisible,
            thickness: 26,
            margin: 0)
        #expect(frame.maxY == notchedVisible.maxY)
        #expect(frame.height == 26)
        #expect(frame.width == notchedVisible.width)
        #expect(BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: notchedVisible) == 26)
    }

    @Test("a positive offset slides a top bar continuously into the camera strip")
    func notchedOffsetEntersStripGradually() {
        let partial = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: notchedVisible,
            thickness: 26,
            margin: 0,
            offsetY: 12)
        #expect(partial.maxY == notchedVisible.maxY + 12)
        #expect(partial.minY == notchedVisible.maxY - 14)
        #expect(BarPlacement.visibleInset(edge: .top, bar: partial,
                                          visibleFrame: notchedVisible) == 14)

        let flush = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: notchedVisible,
            thickness: 26,
            margin: 0,
            offsetY: safeTop)
        #expect(flush.maxY == notchedFrame.maxY)
        #expect(flush.minY == notchedFrame.maxY - 26)
        #expect(BarPlacement.visibleInset(edge: .top, bar: flush,
                                          visibleFrame: notchedVisible) == 0)
    }

    @Test("a floating top bar stays inset from the visible frame, even with a notch")
    func floatingIgnoresNotchStrip() {
        let frame = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: notchedVisible,
            thickness: 24,
            margin: 10)
        #expect(frame.maxY == notchedVisible.maxY - 10)
        #expect(frame.width == notchedVisible.width - 20)
    }

    @Test("the bottom bar always uses the visible frame")
    func bottomIgnoresNotch() {
        let frame = BarPlacement.windowFrame(
            edge: .bottom,
            visibleFrame: notchedVisible,
            thickness: 26,
            margin: 0)
        #expect(frame.minY == notchedVisible.minY)
        #expect(frame.height == 26)
    }

    @Test("vertical offsets move the bar in screen coordinates")
    func offsetsShiftY() {
        let top = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: externalVisible,
            thickness: 26,
            margin: 0,
            offsetY: -12)
        #expect(top.maxY == externalVisible.maxY - 12)

        let bottom = BarPlacement.windowFrame(
            edge: .bottom,
            visibleFrame: externalVisible,
            thickness: 26,
            margin: 0,
            offsetY: 18)
        #expect(bottom.minY == externalVisible.minY + 18)
    }

    @Test("tiling starts at the bar's inner edge, including any offset")
    func tilingFollowsOffsetBar() {
        let topDown = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: externalVisible,
            thickness: 26,
            margin: 0,
            offsetY: -20)
        #expect(BarPlacement.visibleInset(edge: .top, bar: topDown,
                                          visibleFrame: externalVisible) == 46)

        let bottomUp = BarPlacement.windowFrame(
            edge: .bottom,
            visibleFrame: externalVisible,
            thickness: 26,
            margin: 0,
            offsetY: 18)
        #expect(BarPlacement.visibleInset(edge: .bottom, bar: bottomUp,
                                          visibleFrame: externalVisible) == 44)
    }

    @Test("a bar that sits entirely in the notch strip does not shrink the tiling area")
    func notchStripDoesNotInsetVisible() {
        let frame = BarPlacement.windowFrame(
            edge: .top,
            visibleFrame: notchedVisible,
            thickness: 26,
            margin: 0,
            offsetY: safeTop)
        #expect(BarPlacement.visibleInset(edge: .top, bar: frame,
                                          visibleFrame: notchedVisible) == 0)
    }
}
