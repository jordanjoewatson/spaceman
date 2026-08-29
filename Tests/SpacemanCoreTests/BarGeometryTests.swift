import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("Bar geometry")
struct BarGeometryTests {

    private let height: CGFloat = 26
    private let pad = BarGeometry.sectionPadding

    private func plain(_ count: Int) -> [BarSection] {
        (0..<count).map { _ in BarSection(modules: [.clock], fill: .role(.accent)) }
    }

    private func layout(_ sections: [BarSection],
                        widths: [CGFloat],
                        side: ZoneSide = .leading,
                        bleed: CGFloat = 0) -> BarGeometry.ZoneLayout {
        BarGeometry.layout(sections: sections, contentWidths: widths,
                           height: height, side: side, bleed: bleed)
    }

    @Test("no sections lays out nothing")
    func empty() {
        let result = layout([], widths: [])
        #expect(result.sections.isEmpty)
        #expect(result.width == 0)
    }

    @Test("a width for every section is required")
    func mismatchedWidths() {
        // Rather than laying out against a zero width and drawing a collapsed
        // section, which would look like a rendering bug.
        #expect(layout(plain(2), widths: [40]).sections.isEmpty)
    }

    @Test("content is inset from the section edges")
    func padsContent() {
        let result = layout(plain(1), widths: [40])
        #expect(result.sections[0].contentX == pad)
        #expect(result.width == pad + 40 + pad)
    }

    @Test("sections without slants sit flush against each other")
    func straightSectionsAbut() {
        let result = layout(plain(2), widths: [40, 30])
        let first = result.sections[0].quad
        let second = result.sections[1].quad

        // First section's trailing edge is the second's leading edge.
        #expect(first[1].x == second[0].x)
        #expect(first[2].x == second[3].x)
    }

    @Test("adjacent sections share one slanted boundary")
    func slantIsShared() {
        // The reason the geometry is computed centrally: two sections each
        // drawing their own diagonal leaves a wedge of background between them.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 12)

        let result = layout(sections, widths: [40, 30])
        let first = result.sections[0].quad
        let second = result.sections[1].quad

        #expect(first[1] == second[0], "top corners must coincide")
        #expect(first[2] == second[3], "bottom corners must coincide")
    }

    @Test("a down slant pushes the bottom corner out")
    func slantDirectionDown() {
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 10)

        let quad = layout(sections, widths: [40]).sections[0].quad
        let topRight = quad[1]
        let bottomRight = quad[2]
        #expect(bottomRight.x == topRight.x + 10, "\\ leans out at the bottom")
    }

    @Test("an up slant pushes the top corner out")
    func slantDirectionUp() {
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .upSlash, width: 10)

        let quad = layout(sections, widths: [40]).sections[0].quad
        #expect(quad[1].x == quad[2].x + 10, "/ leans out at the top")
    }

    @Test("a following section's leading slant wins over the previous trailing one")
    func leadingSlantOverridesTrailing() {
        // Both declare a boundary; only one diagonal may exist, and the incoming
        // section's intent is the more specific.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 4)
        sections[1].leadingEdge = EdgeShape(style: .upSlash, width: 16)

        let result = layout(sections, widths: [40, 30])
        let boundary = result.sections[0].quad
        #expect(boundary[1].x == boundary[2].x + 16)
    }

    @Test("a slant reserves room so it never cuts into content")
    func slantReservesRoom() {
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 12)

        let result = layout(sections, widths: [40, 30])
        let firstEnd = pad + 40 + pad
        #expect(result.sections[1].contentX == firstEnd + 12 + pad)
    }

    @Test("a leading zone bleeds its outer edge to the bar edge")
    func leadingBleeds() {
        let result = layout(plain(1), widths: [40], side: .leading, bleed: 10)
        let quad = result.sections[0].quad
        #expect(quad[0].x == -10)
        #expect(quad[3].x == -10)
    }

    @Test("a trailing zone bleeds its outer edge to the bar edge")
    func trailingBleeds() {
        let result = layout(plain(1), widths: [40], side: .trailing, bleed: 10)
        let quad = result.sections[0].quad
        #expect(quad[1].x == result.width + 10)
        #expect(quad[2].x == result.width + 10)
    }

    @Test("a center zone bleeds neither edge")
    func centerDoesNotBleed() {
        // There is no bar edge to reach; bleeding would just overhang the
        // neighbouring zones.
        var sections = plain(1)
        sections[0].trailingEdge = .vertical
        let result = layout(sections, widths: [40], side: .center, bleed: 10)
        let quad = result.sections[0].quad
        #expect(quad[0].x == 0)
        #expect(quad[1].x == result.width)
    }

    @Test("a lone trailing section borrows its own slant for its leading edge")
    func loneTrailingSectionSlantsInward() {
        // Otherwise a right-aligned powerline block is a rectangle with one
        // diagonal, which reads as a mistake rather than a style.
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .upSlash, width: 12)

        let result = layout(sections, widths: [40], side: .trailing)
        let quad = result.sections[0].quad
        #expect(quad[0].x != quad[3].x, "leading edge should be slanted")
    }

    @Test("a leading zone's lone section does not borrow a slant")
    func loneLeadingSectionStaysSquare() {
        // Its leading edge is the bar's own edge, which should stay square.
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .upSlash, width: 12)

        let result = layout(sections, widths: [40], side: .leading)
        let quad = result.sections[0].quad
        #expect(quad[0].x == quad[3].x)
    }

    @Test("sections without a fill get no polygon")
    func unfilledSectionsHaveNoQuad() {
        let sections = [BarSection(modules: [.clock])]
        let result = layout(sections, widths: [40])
        #expect(result.sections[0].quad.isEmpty)
        #expect(result.sections[0].contentX == pad, "but still take their place")
    }

    @Test("width covers every section and its slant run-out")
    func widthAccountsForSlants() {
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 12)
        sections[1].trailingEdge = EdgeShape(style: .downSlash, width: 8)

        let result = layout(sections, widths: [40, 30])
        #expect(result.width == (pad + 40 + pad) + 12 + (pad + 30 + pad) + 8)
    }

    // MARK: - Gaps

    @Test("a gap separates two sections instead of joining them")
    func gapSplitsTheBoundary() {
        // The reason a boundary is not always shared: a gap gives each section
        // its own straight edge with bar showing between them.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 10)

        let result = layout(sections, widths: [40, 30])
        let first = result.sections[0].quad
        let second = result.sections[1].quad

        #expect(first[1].x == pad + 40 + pad)
        #expect(second[0].x == first[1].x + 10, "the gap is empty bar")
        #expect(first[1].x != second[0].x)
    }

    @Test("a gap leaves both edges vertical")
    func gapEdgesAreStraight() {
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 10)

        let result = layout(sections, widths: [40, 30])
        #expect(result.sections[0].quad[1].x == result.sections[0].quad[2].x)
        #expect(result.sections[1].quad[0].x == result.sections[1].quad[3].x)
    }

    @Test("a gap pushes the following content along")
    func gapMovesContent() {
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 10)

        let result = layout(sections, widths: [40, 30])
        #expect(result.sections[1].contentX == (pad + 40 + pad) + 10 + pad)
    }

    @Test("a lone section never borrows a gap for its leading edge")
    func gapIsNotBorrowed() {
        // Borrowing a slant makes a lone powerline block symmetrical; borrowing
        // a gap would just inset it from the bar edge, which is not what the
        // user asked for.
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 12)

        let result = layout(sections, widths: [40], side: .center)
        let quad = result.sections[0].quad
        #expect(quad[0].x == 0)
        #expect(quad[0].x == quad[3].x)
    }

    @Test("an uncoloured gap still reports its region, with no fill")
    func plainGapIsAHole() {
        // The renderer needs the rectangle either way: with a fill it paints a
        // divider, without one it cuts the bar's material away so the gap is a
        // hole rather than a space with bar still behind it.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 10)

        let gaps = layout(sections, widths: [40, 30]).gaps
        #expect(gaps.count == 1)
        #expect(gaps[0].fill == nil)
        #expect(gaps[0].rect.width == 10)
        #expect(gaps[0].rect.height == height)
    }

    @Test("a zero-width gap reports nothing")
    func zeroWidthGapIsIgnored() {
        // Otherwise it would punch an empty hole and cost a mask for nothing.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 0)
        #expect(layout(sections, widths: [40, 30]).gaps.isEmpty)
    }

    @Test("only gaps produce regions")
    func slashesProduceNoGaps() {
        // A slash is a line the two neighbours share; it has no area of its own
        // and must never punch a hole.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .downSlash, width: 12)
        #expect(layout(sections, widths: [40, 30]).gaps.isEmpty)
    }

    @Test("a coloured gap gets its own rectangle")
    func colouredGapHasFrame() {
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 10, fill: .role(.separator))

        let result = layout(sections, widths: [40, 30])
        #expect(result.gaps.count == 1)

        let gap = result.gaps[0]
        #expect(gap.fill == ColorRef.role(.separator))
        // Exactly the space between the two sections, full height.
        #expect(gap.quad[0].x == result.sections[0].quad[1].x)
        #expect(gap.quad[1].x == result.sections[1].quad[0].x)
        #expect(gap.quad[0].y == 0)
        #expect(gap.quad[2].y == height)
    }

    @Test("a coloured gap does not move anything")
    func gapFillDoesNotChangeLayout() {
        // Colour is presentation only; the same widths must lay out identically.
        var plainGap = plain(2)
        plainGap[0].trailingEdge = EdgeShape(style: .gap, width: 10)
        var filledGap = plain(2)
        filledGap[0].trailingEdge = EdgeShape(style: .gap, width: 10, fill: .role(.accent))

        let a = layout(plainGap, widths: [40, 30])
        let b = layout(filledGap, widths: [40, 30])
        #expect(a.sections == b.sections)
        #expect(a.width == b.width)
    }

    @Test("a trailing gap on the last section is still recorded")
    func trailingGapRecorded() {
        var sections = plain(1)
        sections[0].trailingEdge = EdgeShape(style: .gap, width: 8, fill: .role(.accent))

        let result = layout(sections, widths: [40], side: .center)
        #expect(result.gaps.count == 1)
        #expect(result.gaps[0].quad[0].x == pad + 40 + pad)
    }

    @Test("a leading gap insets the fill instead of being covered by it")
    func leadingGapIsNotPaintedOver() {
        var sections = plain(1)
        sections[0].leadingEdge = EdgeShape(style: .gap, width: 10, fill: .role(.accent))

        let result = layout(sections, widths: [40], side: .center)
        #expect(result.sections[0].quad[0].x == 10, "section starts after the gap")
        #expect(result.gaps[0].quad[0].x == 0)
        #expect(result.gaps[0].quad[1].x == 10)
    }

    // MARK: - Widths

    @Test("a vertical edge takes no room however wide it claims to be")
    func verticalIgnoresWidth() {
        // So flipping a style back and forth in the editor doesn't lose the
        // width already dialled in.
        var sections = plain(2)
        sections[0].trailingEdge = EdgeShape(style: .vertical, width: 20)

        let result = layout(sections, widths: [40, 30])
        #expect(result.width == (pad + 40 + pad) + (pad + 30 + pad))
    }

    @Test("quads span the full bar height")
    func quadsAreFullHeight() {
        let result = layout(plain(2), widths: [40, 30])
        for frame in result.sections {
            #expect(frame.quad[0].y == 0)
            #expect(frame.quad[1].y == 0)
            #expect(frame.quad[2].y == height)
            #expect(frame.quad[3].y == height)
        }
    }
}
