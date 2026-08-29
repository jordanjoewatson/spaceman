import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Resize weights")
struct ResizeWeightsTests {

    @Test("everything starts at an equal share")
    func startsEqual() {
        let weights = ResizeWeights()
        #expect(weights.width(1) == 1)
        #expect(weights.height(1) == 1)
        #expect(weights.isEmpty, "so the layout takes the equal-split path")
    }

    @Test("growing moves weight from the neighbour, conserving the total")
    func conservesTotal() {
        // The property that makes only one border move: what one gains, the
        // other gives up exactly.
        var weights = ResizeWeights()
        let moved = weights.growWidth(of: 1, from: 2)
        #expect(moved)
        #expect(weights.width(1) == 1 + ResizeWeights.step)
        #expect(weights.width(2) == 1 - ResizeWeights.step)
        #expect(weights.width(1) + weights.width(2) == 2)
    }

    @Test("growing back returns to equal")
    func growingBackUndoes() {
        var weights = ResizeWeights()
        _ = weights.growWidth(of: 1, from: 2)
        _ = weights.growWidth(of: 2, from: 1)
        #expect(abs(weights.width(1) - 1) < 0.0001)
        #expect(abs(weights.width(2) - 1) < 0.0001)
    }

    @Test("a window cannot be squeezed below the floor")
    func respectsFloor() {
        // Without a floor a window shrinks to nothing and becomes unclickable.
        var weights = ResizeWeights()
        for _ in 0..<100 { _ = weights.growWidth(of: 1, from: 2) }
        #expect(weights.width(2) >= ResizeWeights.minimum)
    }

    @Test("a window cannot grow past the ceiling")
    func respectsCeiling() {
        var weights = ResizeWeights()
        for _ in 0..<100 { _ = weights.growWidth(of: 1, from: 2) }
        #expect(weights.width(1) <= ResizeWeights.maximum)
    }

    @Test("a step that cannot move at all reports false")
    func reportsNoMovement() {
        // So the caller skips a re-tile that would change no frame.
        var weights = ResizeWeights()
        var moved = true
        var presses = 0
        while moved, presses < 200 {
            moved = weights.growWidth(of: 1, from: 2)
            presses += 1
        }
        #expect(!moved, "eventually a limit is reached")
        #expect(presses < 200, "and reached in finite time")
    }

    @Test("growing against yourself does nothing")
    func rejectsSelf() {
        var weights = ResizeWeights()
        let moved = weights.growWidth(of: 1, from: 1)
        #expect(!moved)
        #expect(weights.isEmpty)
    }

    @Test("height moves whole sets together")
    func heightMovesSets() {
        // A grid row resizes as a unit: the border belongs to the row, so every
        // member moves by the same amount or the row stops being a row.
        var weights = ResizeWeights()
        let moved = weights.growHeight(of: [1, 2], from: [3, 4])
        #expect(moved)
        #expect(weights.height(1) == weights.height(2))
        #expect(weights.height(3) == weights.height(4))
        #expect(weights.height(1) > 1 && weights.height(3) < 1)
    }

    @Test("overlapping sets are refused")
    func rejectsOverlappingSets() {
        // A window on both sides would gain and give in the same step, which is
        // not a border move.
        var weights = ResizeWeights()
        let moved = weights.growHeight(of: [1, 2], from: [2, 3])
        #expect(!moved)
    }

    @Test("the tightest member limits the whole set")
    func setLimitedByTightestMember() {
        var weights = ResizeWeights()
        // Push one member of the donor set near the floor on its own.
        for _ in 0..<20 { _ = weights.growHeight(of: [9], from: [3]) }
        let before = weights.height(4)
        _ = weights.growHeight(of: [1, 2], from: [3, 4])
        #expect(weights.height(3) >= ResizeWeights.minimum)
        #expect(weights.height(4) <= before, "4 moves only as far as 3 allows")
    }

    @Test("reset returns everything to an equal share")
    func reset() {
        var weights = ResizeWeights()
        _ = weights.growWidth(of: 1, from: 2)
        weights.reset()
        #expect(weights.isEmpty)
        #expect(weights.width(1) == 1)
    }

    @Test("closed windows lose their weights")
    func retainDropsClosedWindows() {
        // Or a reused window id inherits a dead window's share of the layout.
        var weights = ResizeWeights()
        _ = weights.growWidth(of: 1, from: 2)
        weights.retain(only: [1])
        #expect(weights.width(2) == 1)
    }
}

@Suite("Resize navigation")
struct ResizeNavigationTests {

    /// Two columns side by side, each split into two rows:
    ///
    ///     1 | 3
    ///     2 | 4
    private let grid: [CGWindowID: CGRect] = [
        1: CGRect(x: 0, y: 50, width: 100, height: 50),
        2: CGRect(x: 0, y: 0, width: 100, height: 50),
        3: CGRect(x: 100, y: 50, width: 100, height: 50),
        4: CGRect(x: 100, y: 0, width: 100, height: 50),
    ]

    @Test("finds the window sharing the border in that direction")
    func findsAdjacent() {
        #expect(ResizeNavigation.neighbor(of: 1, in: grid, direction: .right) == 3)
        #expect(ResizeNavigation.neighbor(of: 3, in: grid, direction: .left) == 1)
        #expect(ResizeNavigation.neighbor(of: 2, in: grid, direction: .up) == 1)
        #expect(ResizeNavigation.neighbor(of: 1, in: grid, direction: .down) == 2)
    }

    @Test("the layout edge has no neighbour")
    func edgeHasNoNeighbor() {
        // Which is what makes resizing toward the screen edge do nothing, rather
        // than reaching across the layout for something to push.
        #expect(ResizeNavigation.neighbor(of: 1, in: grid, direction: .left) == nil)
        #expect(ResizeNavigation.neighbor(of: 1, in: grid, direction: .up) == nil)
        #expect(ResizeNavigation.neighbor(of: 4, in: grid, direction: .right) == nil)
        #expect(ResizeNavigation.neighbor(of: 4, in: grid, direction: .down) == nil)
    }

    @Test("a window that only touches at a corner is not a neighbour")
    func rejectsCornerTouch() {
        // The difference from focus navigation: there is no shared border to
        // drag, so picking it would move a border that does not exist.
        let corner: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 50, width: 100, height: 50),
            2: CGRect(x: 100, y: 0, width: 100, height: 50),
        ]
        #expect(ResizeNavigation.neighbor(of: 1, in: corner, direction: .right) == nil)
    }

    @Test("the nearest of several candidates wins")
    func picksNearest() {
        let stacked: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 100),
            2: CGRect(x: 100, y: 0, width: 50, height: 100),
            3: CGRect(x: 150, y: 0, width: 50, height: 100),
        ]
        #expect(ResizeNavigation.neighbor(of: 1, in: stacked, direction: .right) == 2)
    }

    @Test("an unknown window has no neighbour")
    func unknownWindow() {
        #expect(ResizeNavigation.neighbor(of: 99, in: grid, direction: .left) == nil)
    }

    @Test("a row is every window in the same horizontal band")
    func rowMembers() {
        let top = grid[1]!
        #expect(ResizeNavigation.rowMembers(of: top, in: grid) == [1, 3])
        let bottom = grid[2]!
        #expect(ResizeNavigation.rowMembers(of: bottom, in: grid) == [2, 4])
    }

    @Test("rows of different heights are different rows")
    func rowsNeedMatchingHeight() {
        let mixed: [CGWindowID: CGRect] = [
            1: CGRect(x: 0, y: 0, width: 100, height: 50),
            2: CGRect(x: 100, y: 0, width: 100, height: 80),
        ]
        #expect(ResizeNavigation.rowMembers(of: mixed[1]!, in: mixed) == [1])
    }
}

@Suite("Weighted layout")
struct WeightedLayoutTests {

    private let area = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let params = LayoutParams(masterRatio: 0.6, gap: 0, outerGap: 0)

    @Test("uniform weights are the equal split, exactly")
    func uniformMatchesUnweighted() {
        // An untouched layout must be bit-identical to what it was before
        // weights existed, or every user sees a one-pixel reflow on upgrade.
        for mode in LayoutMode.allCases {
            for count in 1...6 {
                let plain = Layout.frames(count: count, in: area, mode: mode, params: params)
                let weighted = Layout.frames(count: count, in: area, mode: mode,
                                             params: params,
                                             weights: .equal(count: count))
                #expect(plain == weighted, "\(mode) with \(count)")
            }
        }
    }

    @Test("columns divide in proportion to width weights")
    func weightedColumns() {
        let weights = LayoutWeights(widths: [2, 1], heights: [1, 1])
        let frames = Layout.frames(count: 2, in: area, mode: .columns,
                                   params: params, weights: weights)
        // Compared with a tolerance: the shares are exact fractions, and
        // integer arithmetic in the expectation would silently truncate them.
        #expect(abs(frames[0].width - 1000 * 2.0 / 3.0) < 0.001)
        #expect(abs(frames[1].width - 1000 / 3.0) < 0.001)
    }

    @Test("rows divide in proportion to height weights")
    func weightedRows() {
        let weights = LayoutWeights(widths: [1, 1], heights: [3, 1])
        let frames = Layout.frames(count: 2, in: area, mode: .rows,
                                   params: params, weights: weights)
        #expect(frames[0].height == 450)
        #expect(frames[1].height == 150)
    }

    @Test("weighted frames still fill the area exactly")
    func weightedFramesTile() {
        // No gap, so the parts must add back to the whole — a rounding slip here
        // shows as a permanent seam between two windows.
        let weights = LayoutWeights(widths: [2.5, 1, 0.5, 1], heights: [1, 2, 1, 1])
        let frames = Layout.frames(count: 4, in: area, mode: .spaceman,
                                   params: params, weights: weights)
        let total = frames.reduce(0) { $0 + $1.width * $1.height }
        #expect(abs(total - area.width * area.height) < 1)
    }

    @Test("a grid row keeps a single height across its members")
    func gridRowsStayLevel() {
        // Rows are given the mean of their members' height weights, so a row
        // whose windows disagree still moves as one band rather than tearing.
        let weights = LayoutWeights(widths: [1, 1, 1, 1], heights: [2, 1, 1, 1])
        let frames = Layout.frames(count: 4, in: area, mode: .spaceman,
                                   params: params, weights: weights)
        #expect(frames[0].height == frames[1].height, "top row")
        #expect(frames[2].height == frames[3].height, "bottom row")
        #expect(frames[0].height > frames[2].height, "the heavier row is taller")
    }

    @Test("the master column ignores weights")
    func masterIgnoresWidthWeights() {
        // Its border is the master ratio, which horizontal resizing moves
        // instead of a weight.
        let weights = LayoutWeights(widths: [3, 1, 1], heights: [1, 1, 1])
        let frames = Layout.frames(count: 3, in: area, mode: .masterStack,
                                   params: params, weights: weights)
        #expect(frames[0].width == 600)
    }

    @Test("the master stack divides by height weight")
    func masterStackUsesHeightWeights() {
        let weights = LayoutWeights(widths: [1, 1, 1], heights: [1, 3, 1])
        let frames = Layout.frames(count: 3, in: area, mode: .masterStack,
                                   params: params, weights: weights)
        #expect(frames[1].height == 450)
        #expect(frames[2].height == 150)
    }

    @Test("nonsense weights fall back to an equal split")
    func badWeightsDegrade() {
        // Bad weights should degrade to the default layout, not to a
        // zero-width window.
        let broken = LayoutWeights(widths: [0, -1], heights: [0, 0])
        let frames = Layout.frames(count: 2, in: area, mode: .columns,
                                   params: params, weights: broken)
        #expect(frames[0].width == 500)
        #expect(frames[1].width == 500)
    }

    @Test("weights shorter than the slot count are tolerated")
    func shortWeightArrays() {
        let short = LayoutWeights(widths: [2], heights: [2])
        let frames = Layout.frames(count: 3, in: area, mode: .columns,
                                   params: params, weights: short)
        #expect(frames.count == 3)
        #expect(frames[0].width > frames[1].width, "the declared slot still counts")
    }
}
