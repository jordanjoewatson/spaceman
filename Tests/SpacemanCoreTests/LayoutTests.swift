import Testing
import CoreGraphics
@testable import SpacemanCore

private let area = CGRect(x: 0, y: 0, width: 1000, height: 800)
private let noGaps = LayoutParams(masterRatio: 0.5, gap: 0, outerGap: 0)

@Suite("Layout")
struct LayoutTests {

    @Test("every mode returns exactly one frame per window", arguments: LayoutMode.allCases)
    func frameCountMatchesWindowCount(mode: LayoutMode) {
        for n in 1...8 {
            let frames = Layout.frames(count: n, in: area, mode: mode)
            #expect(frames.count == n, "\(mode) with \(n) windows")
        }
    }

    @Test("no frames for zero windows or a degenerate area", arguments: LayoutMode.allCases)
    func degenerateInputsYieldNothing(mode: LayoutMode) {
        #expect(Layout.frames(count: 0, in: area, mode: mode).isEmpty)
        #expect(Layout.frames(count: 3, in: .zero, mode: mode).isEmpty)
        // An area smaller than the outer gap on both sides must not produce
        // negative-size rects.
        let tiny = CGRect(x: 0, y: 0, width: 4, height: 4)
        #expect(Layout.frames(count: 2, in: tiny, mode: mode).isEmpty)
    }

    @Test("frames never have negative or zero dimensions", arguments: LayoutMode.allCases)
    func framesAreWellFormed(mode: LayoutMode) {
        for n in 1...10 {
            for frame in Layout.frames(count: n, in: area, mode: mode) {
                #expect(frame.width > 0, "\(mode)/\(n) width \(frame.width)")
                #expect(frame.height > 0, "\(mode)/\(n) height \(frame.height)")
            }
        }
    }

    @Test("frames stay inside the available area", arguments: LayoutMode.allCases)
    func framesStayInBounds(mode: LayoutMode) {
        let slack: CGFloat = 0.001
        for n in 1...10 {
            for frame in Layout.frames(count: n, in: area, mode: mode) {
                #expect(frame.minX >= area.minX - slack)
                #expect(frame.minY >= area.minY - slack)
                #expect(frame.maxX <= area.maxX + slack)
                #expect(frame.maxY <= area.maxY + slack)
            }
        }
    }

    @Test("a single window fills the area minus the outer gap", arguments: LayoutMode.allCases)
    func singleWindowFillsArea(mode: LayoutMode) {
        let params = LayoutParams(masterRatio: 0.5, gap: 8, outerGap: 10)
        let frames = Layout.frames(count: 1, in: area, mode: mode, params: params)
        #expect(frames == [area.insetBy(dx: 10, dy: 10)])
    }

    // MARK: - Per-mode geometry

    @Test("columns divide the width evenly and tile without overlap")
    func columnsAreEvenAndContiguous() {
        let frames = Layout.frames(count: 4, in: area, mode: .columns, params: noGaps)
        #expect(frames.map(\.width).allSatisfy { abs($0 - 250) < 0.001 })
        #expect(frames.allSatisfy { abs($0.height - 800) < 0.001 })
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(abs(a.maxX - b.minX) < 0.001, "columns should be contiguous")
        }
    }

    @Test("rows divide the height evenly, first frame at the top")
    func rowsAreEvenAndTopDown() {
        let frames = Layout.frames(count: 4, in: area, mode: .rows, params: noGaps)
        #expect(frames.map(\.height).allSatisfy { abs($0 - 200) < 0.001 })
        // Bottom-left origin: the first row is the highest one on screen.
        #expect(frames[0].minY > frames[1].minY)
        #expect(abs(frames[0].maxY - area.maxY) < 0.001)
    }

    @Test("masterStack gives the master its ratio of the width")
    func masterStackHonoursRatio() {
        let params = LayoutParams(masterRatio: 0.7, gap: 0, outerGap: 0)
        let frames = Layout.frames(count: 3, in: area, mode: .masterStack, params: params)
        #expect(abs(frames[0].width - 700) < 0.001)
        // The two stacked windows share the remaining 300pt column.
        #expect(abs(frames[1].width - 300) < 0.001)
        #expect(abs(frames[2].width - 300) < 0.001)
        #expect(abs(frames[1].height - 400) < 0.001)
    }

    @Test("masterStack clamps out-of-range ratios instead of inverting the layout")
    func masterRatioIsClamped() {
        let wild = LayoutParams(masterRatio: 5.0, gap: 0, outerGap: 0)
        let frames = Layout.frames(count: 2, in: area, mode: .masterStack, params: wild)
        #expect(frames[0].width <= area.width)
        #expect(frames[1].width > 0, "stack must not be squeezed out of existence")
    }

    @Test("master ratio clamps to the Go version's range, 0.1...0.9")
    func masterRatioClampBoundaries() {
        let high = LayoutParams(masterRatio: 5.0, gap: 0, outerGap: 0)
        let highFrames = Layout.frames(count: 2, in: area, mode: .masterStack, params: high)
        #expect(abs(highFrames[0].width - 900) < 0.001, "5.0 should clamp to 0.9")

        let low = LayoutParams(masterRatio: -2.0, gap: 0, outerGap: 0)
        let lowFrames = Layout.frames(count: 2, in: area, mode: .masterStack, params: low)
        #expect(abs(lowFrames[0].width - 100) < 0.001, "-2.0 should clamp to 0.1")
    }

    // MARK: - Spaceman grid (parity with the Go engine's default layout)

    @Test("grid cells exactly cover the area when there are no gaps")
    func gridFillsArea() {
        for n in 1...8 {
            let frames = Layout.frames(count: n, in: area, mode: .spaceman, params: noGaps)
            let covered = frames.reduce(CGFloat(0)) { $0 + $1.width * $1.height }
            #expect(abs(covered - area.width * area.height) < 1,
                    "n=\(n): cells cover \(covered), want \(area.width * area.height)")
        }
    }

    @Test("grid shapes match the Go version: 2 side-by-side, 4 = 2x2, 3 = two up one wide below")
    func gridShapesMatchGo() {
        let wide = CGRect(x: 0, y: 0, width: 900, height: 600)

        let two = Layout.frames(count: 2, in: wide, mode: .spaceman, params: noGaps)
        #expect(abs(two[0].width - 450) < 0.001 && abs(two[0].height - 600) < 0.001)

        let four = Layout.frames(count: 4, in: wide, mode: .spaceman, params: noGaps)
        #expect(abs(four[0].width - 450) < 0.001 && abs(four[0].height - 300) < 0.001)

        let three = Layout.frames(count: 3, in: wide, mode: .spaceman, params: noGaps)
        #expect(abs(three[2].width - 900) < 0.001, "3rd window spans full width")
        // Bottom-left origin: the full-width cell is the lowest on screen, and
        // the first row starts at the top of the area.
        #expect(three[2].minY < three[0].minY)
        #expect(abs(three[0].maxY - wide.maxY) < 0.001)
    }

    @Test("grid keeps slot order row by row: 5 = three up, two below")
    func gridFiveWindows() {
        let frames = Layout.frames(count: 5, in: area, mode: .spaceman, params: noGaps)
        // Row of 3 on top, row of 2 below (AppKit: top row has the larger minY).
        #expect(frames[0].minY > frames[3].minY)
        #expect(abs(frames[0].width - frames[1].width) < 0.001)
        #expect(abs(frames[3].width - frames[4].width) < 0.001)
        #expect(frames[3].width > frames[0].width, "2-cell row is wider than 3-cell row")
    }

    @Test("monocle stacks every window on the same rect")
    func monocleOverlapsEverything() {
        let frames = Layout.frames(count: 5, in: area, mode: .monocle, params: noGaps)
        #expect(Set(frames.map(\.debugDescription)).count == 1)
    }

    @Test("bsp tiles the area without overlapping")
    func bspDoesNotOverlap() {
        let frames = Layout.frames(count: 5, in: area, mode: .bsp, params: noGaps)
        for i in frames.indices {
            for j in frames.indices where j > i {
                let overlap = frames[i].intersection(frames[j])
                #expect(overlap.isNull || overlap.width < 0.001 || overlap.height < 0.001,
                        "frames \(i) and \(j) overlap: \(overlap)")
            }
        }
    }

    @Test("gaps shrink tiles rather than pushing them out of bounds")
    func gapsAreAbsorbed() {
        let gappy = LayoutParams(masterRatio: 0.5, gap: 20, outerGap: 30)
        let frames = Layout.frames(count: 3, in: area, mode: .columns, params: gappy)
        #expect(abs(frames[0].minX - 30) < 0.001)
        #expect(abs(frames[2].maxX - 970) < 0.001)
        for (a, b) in zip(frames, frames.dropFirst()) {
            #expect(abs(b.minX - a.maxX - 20) < 0.001, "gap between tiles should be exactly 20")
        }
    }

    @Test("cycling through modes returns to the start")
    func modeCyclingWraps() {
        var mode = LayoutMode.masterStack
        for _ in LayoutMode.allCases { mode = mode.next }
        #expect(mode == .masterStack)
    }
}

@Suite("Reconciler")
struct ReconcilerTests {

    private func window(_ id: CGWindowID, _ frame: CGRect) -> ManagedWindow {
        ManagedWindow(id: id, pid: 1, ownerName: "Test", frame: frame, zOrder: Int(id))
    }

    @Test("windows already in place produce no moves")
    func placedWindowsAreSkipped() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let moves = Reconciler.moves(windows: [window(1, target)], targets: [target])
        #expect(moves.isEmpty)
    }

    @Test("a window within tolerance counts as placed")
    func toleranceAbsorbsSmallDrift() {
        // Apps with size increments (terminals) land a point or two off. If this
        // counted as unplaced we would re-issue the move forever.
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let actual = CGRect(x: 2, y: 1, width: 98, height: 100)
        let moves = Reconciler.moves(windows: [window(1, actual)], targets: [target], tolerance: 4)
        #expect(moves.isEmpty)
    }

    @Test("a window beyond tolerance produces one move to the target")
    func displacedWindowsAreMoved() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let actual = CGRect(x: 500, y: 500, width: 100, height: 100)
        let moves = Reconciler.moves(windows: [window(7, actual)], targets: [target])
        #expect(moves.count == 1)
        #expect(moves[0].window.id == 7)
        #expect(moves[0].target == target)
    }

    @Test("extra windows without a target are left alone")
    func unmatchedWindowsAreIgnored() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 100)
        let windows = [window(1, .zero), window(2, .zero), window(3, .zero)]
        let moves = Reconciler.moves(windows: windows, targets: [target])
        #expect(moves.count == 1, "zip should stop at the shorter sequence")
    }
}
