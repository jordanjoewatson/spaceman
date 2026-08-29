import CoreGraphics

/// Lays out a zone's sections and works out the polygon behind each one.
///
/// The whole point is the *shared* boundary. A naive implementation gives every
/// section its own left and right edge, and two adjacent slants then leave a
/// wedge of background showing between them. Here a boundary is computed once
/// and used as the trailing edge of one section and the leading edge of the
/// next, so their fills meet along a single diagonal with nothing between.
///
/// Pure geometry, so the awkward cases — a lone section, a section with slants
/// on both sides, an edge zone bleeding past the bar's padding — are testable
/// without rendering anything.
public enum BarGeometry {

    /// Gap between a section's boundary and its content, so modules never touch
    /// the fill edge or get clipped by a diagonal.
    public static let sectionPadding: CGFloat = 8

    /// A boundary between two sections: the x of its top and bottom corners.
    /// Equal values are a straight edge; differing ones a diagonal.
    public struct Boundary: Equatable, Sendable {
        public var top: CGFloat
        public var bottom: CGFloat

        public init(top: CGFloat, bottom: CGFloat) {
            self.top = top
            self.bottom = bottom
        }

        public var isStraight: Bool { top == bottom }

        public static func straight(_ x: CGFloat) -> Boundary {
            Boundary(top: x, bottom: x)
        }
    }

    /// Where one section's fill and content go.
    public struct SectionFrame: Equatable, Sendable {
        /// The fill quad, clockwise from the top-leading corner. Empty when the
        /// section has no fill.
        public var quad: [CGPoint]
        /// Where the module row starts.
        public var contentX: CGFloat
        public var contentWidth: CGFloat
    }

    /// The region a `gap` edge occupies.
    ///
    /// A fill paints it as a divider. No fill makes it a hole: the renderer
    /// masks the bar's own material out of it, so the desktop shows through
    /// rather than the bar continuing behind the space.
    public struct GapFrame: Equatable, Sendable {
        public var quad: [CGPoint]
        public var fill: ColorRef?

        /// Gaps are axis-aligned, so this is exact rather than a bounding box.
        public var rect: CGRect {
            guard let first = quad.first, quad.count == 4 else { return .zero }
            let minX = quad.map(\.x).min() ?? first.x
            let maxX = quad.map(\.x).max() ?? first.x
            let minY = quad.map(\.y).min() ?? first.y
            let maxY = quad.map(\.y).max() ?? first.y
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
    }

    public struct ZoneLayout: Equatable, Sendable {
        public var sections: [SectionFrame]
        /// Coloured gaps, to paint alongside the section fills.
        public var gaps: [GapFrame]
        /// Total width the zone occupies, including slant run-out and gaps.
        public var width: CGFloat
    }

    /// Lay out `sections` given the measured width of each one's content.
    ///
    /// `bleed` is how far the outermost boundary of an edge zone extends past
    /// the zone's own origin, cancelling the bar's edge padding so a filled
    /// section reaches the bar's edge instead of stopping short of it.
    public static func layout(sections: [BarSection],
                              contentWidths: [CGFloat],
                              height: CGFloat,
                              side: ZoneSide,
                              bleed: CGFloat = 0,
                              padding: CGFloat = sectionPadding) -> ZoneLayout {
        guard !sections.isEmpty, sections.count == contentWidths.count else {
            return ZoneLayout(sections: [], gaps: [], width: 0)
        }

        // A lone section in a center or trailing zone has no neighbour to slant
        // against, so its leading edge borrows its own trailing slant. Without
        // this a right-aligned powerline section would be a rectangle with one
        // diagonal, which reads as a mistake rather than a style. A gap is not
        // borrowed — an inset on the outer side is not what "gap" asked for.
        var leadEdge = sections[0].leadingEdge
        if leadEdge.style == .vertical, side == .trailing || side == .center,
           sections[0].trailingEdge.style.isShared {
            leadEdge = sections[0].trailingEdge
        }

        let count = sections.count
        // Each section owns both its boundaries. A slanted edge writes the same
        // line into two neighbours; a gap writes two different ones, which is
        // exactly what makes it a gap rather than a shape.
        var leadingBoundary = [Boundary](repeating: .straight(0), count: count)
        var trailingBoundary = [Boundary](repeating: .straight(0), count: count)
        var contentX = [CGFloat](repeating: 0, count: count)
        var gaps: [GapFrame] = []

        /// A gap's own region. Recorded whether or not it has a colour: an
        /// uncoloured gap still needs its rectangle, so the renderer can cut the
        /// bar's material away from it.
        func recordGap(_ edge: EdgeShape, from start: CGFloat) {
            guard edge.style == .gap, edge.reservedWidth > 0 else { return }
            let fill = edge.fill
            let end = start + CGFloat(edge.reservedWidth)
            gaps.append(GapFrame(quad: [
                CGPoint(x: start, y: 0),
                CGPoint(x: end, y: 0),
                CGPoint(x: end, y: height),
                CGPoint(x: start, y: height),
            ], fill: fill))
        }

        // Walk left to right, reserving room for the leading edge first so a
        // diagonal never cuts into the first section's content.
        var x = CGFloat(leadEdge.reservedWidth)
        leadingBoundary[0] = leading(leadEdge)
        recordGap(leadEdge, from: 0)

        for index in 0..<count {
            contentX[index] = x + padding
            let end = x + padding + contentWidths[index] + padding

            // The edge after this section: the next section's leading edge wins
            // if it declares one, otherwise this section's trailing edge. Only
            // one of the two can shape the boundary, and the incoming section's
            // intent is the more specific.
            var edge = sections[index].trailingEdge
            if index < count - 1, sections[index + 1].leadingEdge.style != .vertical {
                edge = sections[index + 1].leadingEdge
            }
            let reserved = CGFloat(edge.reservedWidth)

            switch edge.style {
            case .vertical:
                trailingBoundary[index] = .straight(end)
                if index < count - 1 { leadingBoundary[index + 1] = .straight(end) }
            case .downSlash:
                let shared = Boundary(top: end, bottom: end + reserved)
                trailingBoundary[index] = shared
                if index < count - 1 { leadingBoundary[index + 1] = shared }
            case .upSlash:
                let shared = Boundary(top: end + reserved, bottom: end)
                trailingBoundary[index] = shared
                if index < count - 1 { leadingBoundary[index + 1] = shared }
            case .gap:
                // Two separate straight boundaries with bar showing between —
                // unless the gap was given a fill, in which case that region is
                // painted in its own right.
                trailingBoundary[index] = .straight(end)
                if index < count - 1 { leadingBoundary[index + 1] = .straight(end + reserved) }
                recordGap(edge, from: end)
            }

            x = end + reserved
        }
        let width = x

        // An edge zone's outer boundary runs flush to the bar end: a fill that
        // stopped at the padding would look like a misaligned block rather than
        // part of the bar.
        switch side {
        case .leading:  leadingBoundary[0] = .straight(-bleed)
        case .trailing: trailingBoundary[count - 1] = .straight(width + bleed)
        case .center:   break
        }

        let frames = (0..<count).map { index -> SectionFrame in
            let start = leadingBoundary[index]
            let end = trailingBoundary[index]
            let quad = sections[index].fill == nil ? [] : [
                CGPoint(x: start.top, y: 0),
                CGPoint(x: end.top, y: 0),
                CGPoint(x: end.bottom, y: height),
                CGPoint(x: start.bottom, y: height),
            ]
            return SectionFrame(quad: quad,
                                contentX: contentX[index],
                                contentWidth: contentWidths[index])
        }

        return ZoneLayout(sections: frames, gaps: gaps, width: width)
    }

    /// The first section's leading boundary, drawn inside the room reserved for
    /// it.
    ///
    /// A slash starts at the origin and cuts across the reserved room. A gap
    /// starts *after* it — the reserved room is the gap, so a fill that began at
    /// the origin would paint straight over it.
    private static func leading(_ edge: EdgeShape) -> Boundary {
        let width = CGFloat(edge.reservedWidth)
        switch edge.style {
        case .vertical:  return .straight(0)
        case .gap:       return .straight(width)
        case .downSlash: return Boundary(top: 0, bottom: width)
        case .upSlash:   return Boundary(top: width, bottom: 0)
        }
    }
}
