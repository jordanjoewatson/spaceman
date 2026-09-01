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
        let thickness = BarPlacement.thickness(
            edge: .top, requested: 26, floating: false, safeAreaTop: 0)
        #expect(thickness == 26)

        let frame = BarPlacement.windowFrame(
            edge: .top,
            screenFrame: externalFrame,
            visibleFrame: externalVisible,
            safeAreaTop: 0,
            thickness: thickness,
            margin: 0)
        #expect(frame.maxY == externalVisible.maxY)
        #expect(frame.height == 26)
        #expect(frame.width == externalVisible.width)
        #expect(BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: externalVisible) == 26)
    }

    @Test("a flush top bar on a notched display fills the camera strip")
    func notchedFlushTopFillsEars() {
        let thickness = BarPlacement.thickness(
            edge: .top, requested: 26, floating: false, safeAreaTop: safeTop)
        #expect(thickness == safeTop)

        let frame = BarPlacement.windowFrame(
            edge: .top,
            screenFrame: notchedFrame,
            visibleFrame: notchedVisible,
            safeAreaTop: safeTop,
            thickness: thickness,
            margin: 0)
        #expect(frame.maxY == notchedFrame.maxY)
        #expect(frame.minY == notchedVisible.maxY)
        #expect(frame.width == notchedFrame.width)
        #expect(BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: notchedVisible) == 0)
    }

    @Test("a preset taller than the notch keeps its height")
    func tallerThanNotch() {
        let thickness = BarPlacement.thickness(
            edge: .top, requested: 48, floating: false, safeAreaTop: safeTop)
        #expect(thickness == 48)

        let frame = BarPlacement.windowFrame(
            edge: .top,
            screenFrame: notchedFrame,
            visibleFrame: notchedVisible,
            safeAreaTop: safeTop,
            thickness: thickness,
            margin: 0)
        #expect(frame.maxY == notchedFrame.maxY)
        #expect(BarPlacement.visibleHeightUsed(bar: frame, visibleFrame: notchedVisible) == 10)
    }

    @Test("a floating top bar stays in the visible frame, even with a notch")
    func floatingIgnoresNotchStrip() {
        let thickness = BarPlacement.thickness(
            edge: .top, requested: 24, floating: true, safeAreaTop: safeTop)
        #expect(thickness == 24)

        let frame = BarPlacement.windowFrame(
            edge: .top,
            screenFrame: notchedFrame,
            visibleFrame: notchedVisible,
            safeAreaTop: safeTop,
            thickness: thickness,
            margin: 10)
        #expect(frame.maxY == notchedVisible.maxY - 10)
        #expect(frame.width == notchedVisible.width - 20)
    }

    @Test("the bottom bar always uses the visible frame")
    func bottomIgnoresNotch() {
        let frame = BarPlacement.windowFrame(
            edge: .bottom,
            screenFrame: notchedFrame,
            visibleFrame: notchedVisible,
            safeAreaTop: safeTop,
            thickness: 26,
            margin: 0)
        #expect(frame.minY == notchedVisible.minY)
        #expect(frame.height == 26)
    }

    @Test("the camera housing converts into bar-local x")
    func notchCutoutIsLocal() {
        // Left ear 640pt, housing 180pt, right ear the rest, bar at x=0.
        let cutout = BarPlacement.notchCutout(barMinX: 0,
                                              leftAuxMaxX: 640,
                                              rightAuxMinX: 820)
        #expect(cutout?.minX == 640)
        #expect(cutout?.width == 180)
    }

    @Test("no housing produces no cutout")
    func noCutoutWithoutNotch() {
        #expect(BarPlacement.notchCutout(barMinX: 0,
                                         leftAuxMaxX: 0,
                                         rightAuxMinX: 0) == nil)
    }
}
