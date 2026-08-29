import CoreGraphics

/// How windows on the current space are arranged.
///
/// Every mode is a pure function of (window count, available rect, params), so
/// the whole engine is testable without a window server.
public enum LayoutMode: String, CaseIterable, Sendable {
    /// The Go version's default grid: ⌈√n⌉ columns, a partial last row
    /// stretched to full width. 2 → side by side, 3 → two up + one wide below,
    /// 4 → 2×2, 5 → 3+2, 6 → 3×2.
    case spaceman
    /// One master window on the left, everything else stacked on the right.
    case masterStack
    /// Recursive binary split, alternating vertical/horizontal.
    case bsp
    /// Equal-width columns.
    case columns
    /// Equal-height rows.
    case rows
    /// Every window fills the whole area; only the focused one is visible.
    case monocle

    public var next: LayoutMode {
        let all = LayoutMode.allCases
        let i = all.firstIndex(of: self)!
        return all[(i + 1) % all.count]
    }

    /// Parse a mode from something a person typed.
    ///
    /// The raw values are Swift-ish (`masterStack`), but a config file or a URL
    /// is written by hand — nobody types camel case there. Accepting the obvious
    /// spellings costs one table and removes the most likely reason a custom
    /// command silently fails to load.
    public init?(userInput: String) {
        switch userInput.lowercased() {
        case "spaceman", "grid", "tile":                      self = .spaceman
        case "master", "masterstack", "master-stack", "main": self = .masterStack
        case "bsp", "binary", "split":                        self = .bsp
        case "columns", "column", "cols", "col", "vertical":  self = .columns
        case "rows", "row", "horizontal":                     self = .rows
        case "monocle", "mono", "full", "fullscreen", "max":  self = .monocle
        default: return nil
        }
    }

    public var shortName: String {
        switch self {
        case .spaceman:    return "GRID"
        case .masterStack: return "MASTER"
        case .bsp:         return "BSP"
        case .columns:     return "COLS"
        case .rows:        return "ROWS"
        case .monocle:     return "MONO"
        }
    }
}

public struct LayoutParams: Sendable, Equatable {
    /// Fraction of the width given to the master window, clamped to 0.1...0.9
    /// (same range as the Go version's master layout).
    public var masterRatio: CGFloat
    /// Space between adjacent windows.
    public var gap: CGFloat
    /// Space between the windows and the edge of the available rect.
    public var outerGap: CGFloat

    /// Defaults match the Go version: master_ratio 0.6, gap 12 (used for both
    /// the outer margin and the space between tiles there too).
    public init(masterRatio: CGFloat = 0.6, gap: CGFloat = 12, outerGap: CGFloat = 12) {
        self.masterRatio = masterRatio
        self.gap = gap
        self.outerGap = outerGap
    }

    public static let `default` = LayoutParams()

    public func withMasterRatio(_ r: CGFloat) -> LayoutParams {
        var copy = self
        copy.masterRatio = min(max(r, 0.1), 0.9)
        return copy
    }
}

public enum Layout {
    /// A rect covering `fraction` of `area`, centered — where a zoomed window
    /// floats (the Go version's `centeredFraction(area, 0.8)`).
    public static func centered(in area: CGRect, fraction: CGFloat) -> CGRect {
        let w = area.width * fraction
        let h = area.height * fraction
        return CGRect(x: area.minX + (area.width - w) / 2,
                      y: area.minY + (area.height - h) / 2,
                      width: w, height: h)
    }

    /// Frames for `count` windows inside `area`.
    ///
    /// Returns exactly `count` rects in stable order — element *i* is where
    /// window *i* belongs. An empty or degenerate `area` yields no rects, which
    /// keeps callers from issuing moves to nonsense coordinates.
    /// `weights` gives each slot its share relative to its siblings; nil, or an
    /// all-ones set, is the equal split. BSP ignores them — its geometry is a
    /// recursive halving with no sibling row to redistribute within, which is
    /// why the Go version leaves it alone too.
    public static func frames(
        count: Int,
        in area: CGRect,
        mode: LayoutMode,
        params: LayoutParams = .default,
        weights: LayoutWeights? = nil
    ) -> [CGRect] {
        guard count > 0, area.width > 1, area.height > 1 else { return [] }

        let inner = area.insetBy(dx: params.outerGap, dy: params.outerGap)
        guard inner.width > 1, inner.height > 1 else { return [] }

        // An untouched layout takes the equal-split path, so it stays exactly
        // what it was before weights existed.
        let weights = (weights?.isUniform ?? true) ? nil : weights

        switch mode {
        case .monocle:
            return Array(repeating: inner, count: count)
        case .columns:
            return split(inner, into: count, axis: .vertical, gap: params.gap,
                         shares: (0..<count).map { weights?.width($0) ?? 1 })
        case .rows:
            return split(inner, into: count, axis: .horizontal, gap: params.gap,
                         shares: (0..<count).map { weights?.height($0) ?? 1 })
        case .spaceman:
            return spacemanGrid(inner, count: count, gap: params.gap, weights: weights)
        case .masterStack:
            return masterStack(inner, count: count, params: params, weights: weights)
        case .bsp:
            return bsp(inner, count: count, gap: params.gap)
        }
    }

    // MARK: - Modes

    /// Direct port of the Go version's default grid (`internal/core/engine/grid.go`).
    ///
    /// Columns = ⌈√count⌉, rows = ⌈count/columns⌉, filled row by row; a partial
    /// last row stretches to span the full width, so windows are as equal as
    /// possible with no empty slots. (The Go version also carries per-window
    /// resize weights; those exist only for its interactive resize, so the equal
    /// split here is its exact default behaviour.)
    private static func spacemanGrid(_ rect: CGRect, count n: Int, gap: CGFloat,
                                     weights: LayoutWeights? = nil) -> [CGRect] {
        let cols = Int(ceil(sqrt(CGFloat(n))))
        let rows = Int(ceil(CGFloat(n) / CGFloat(cols)))

        // Row membership: fill `cols` at a time, the last row takes the rest.
        var rowLen: [Int] = []
        rowLen.reserveCapacity(rows)
        var placed = 0
        for _ in 0..<rows {
            let inRow = min(cols, n - placed)
            rowLen.append(inRow)
            placed += inRow
        }

        // A row's height share is the mean of its members', so a row whose
        // windows disagree still moves as one band rather than tearing.
        var slot = 0
        let rowShares: [Double] = rowLen.map { len in
            defer { slot += len }
            guard let weights else { return 1 }
            let members = (slot..<(slot + len)).map { weights.height($0) }
            return members.reduce(0, +) / Double(members.count)
        }

        let rowHeights = lengths(total: rect.height, count: rows, gap: gap, shares: rowShares)
        guard rowHeights.allSatisfy({ $0 > 0 }) else {
            return Array(repeating: rect, count: n)
        }

        var out: [CGRect] = []
        out.reserveCapacity(n)
        // Bottom-left origin: row 0 is the *top* row, walk down from maxY.
        var y = rect.maxY
        slot = 0
        for (row, len) in rowLen.enumerated() {
            let rowH = rowHeights[row]
            y -= rowH

            let shares = (slot..<(slot + len)).map { weights?.width($0) ?? 1 }
            let cellWidths = lengths(total: rect.width, count: len, gap: gap, shares: shares)
            guard cellWidths.allSatisfy({ $0 > 0 }) else {
                return Array(repeating: rect, count: n)
            }

            var x = rect.minX
            for cell in 0..<len {
                out.append(CGRect(x: x, y: y, width: cellWidths[cell], height: rowH))
                x += cellWidths[cell] + gap
            }
            y -= gap
            slot += len
        }
        return out
    }

    private static func masterStack(_ rect: CGRect, count: Int, params: LayoutParams,
                                    weights: LayoutWeights? = nil) -> [CGRect] {
        if count == 1 { return [rect] }

        let ratio = min(max(params.masterRatio, 0.1), 0.9)
        let masterWidth = (rect.width - params.gap) * ratio
        let stackWidth = rect.width - params.gap - masterWidth

        let master = CGRect(x: rect.minX, y: rect.minY, width: masterWidth, height: rect.height)
        let stackArea = CGRect(x: rect.minX + masterWidth + params.gap, y: rect.minY,
                               width: stackWidth, height: rect.height)

        // Only the stack redistributes: the master/stack border is the master
        // ratio, which horizontal resizing moves instead of a weight.
        let shares = (1..<count).map { weights?.height($0) ?? 1 }
        return [master] + split(stackArea, into: count - 1, axis: .horizontal,
                                gap: params.gap, shares: shares)
    }

    /// Classic binary space partition: split the remaining area in half, put one
    /// window in the first half, recurse into the second with the rest.
    private static func bsp(_ rect: CGRect, count: Int, gap: CGFloat) -> [CGRect] {
        if count <= 1 { return [rect] }

        // Split along the longer edge so tiles trend toward square.
        let axis: Axis = rect.width >= rect.height ? .vertical : .horizontal
        let halves = split(rect, into: 2, axis: axis, gap: gap)
        guard halves.count == 2 else { return [rect] }

        return [halves[0]] + bsp(halves[1], count: count - 1, gap: gap)
    }

    // MARK: - Splitting

    private enum Axis { case vertical, horizontal }

    /// Divide `rect` into `n` equal parts. `.vertical` splits left-to-right;
    /// `.horizontal` splits top-to-bottom in screen terms — note this rect space
    /// is bottom-left origin (AppKit), so index 0 is the *top* row.
    private static func split(_ rect: CGRect, into n: Int, axis: Axis, gap: CGFloat,
                              shares: [Double]? = nil) -> [CGRect] {
        guard n > 0 else { return [] }
        if n == 1 { return [rect] }

        let shares = shares ?? Array(repeating: 1, count: n)

        switch axis {
        case .vertical:
            let widths = lengths(total: rect.width, count: n, gap: gap, shares: shares)
            guard widths.allSatisfy({ $0 > 0 }) else {
                return Array(repeating: rect, count: n)
            }
            var x = rect.minX
            return (0..<n).map { i in
                defer { x += widths[i] + gap }
                return CGRect(x: x, y: rect.minY, width: widths[i], height: rect.height)
            }
        case .horizontal:
            let heights = lengths(total: rect.height, count: n, gap: gap, shares: shares)
            guard heights.allSatisfy({ $0 > 0 }) else {
                return Array(repeating: rect, count: n)
            }
            // Index 0 at the top: walk down from maxY.
            var y = rect.maxY
            return (0..<n).map { i in
                y -= heights[i]
                defer { y -= gap }
                return CGRect(x: rect.minX, y: y, width: rect.width, height: heights[i])
            }
        }
    }

    /// Divide `total` into `count` parts in proportion to `shares`, after the
    /// gaps are taken out.
    ///
    /// Non-positive or mismatched shares fall back to an equal split rather than
    /// producing a zero-width window — bad weights should degrade to the default
    /// layout, not to something unusable.
    private static func lengths(total: CGFloat, count: Int, gap: CGFloat,
                                shares: [Double]) -> [CGFloat] {
        guard count > 0 else { return [] }
        let available = total - gap * CGFloat(count - 1)
        guard available > 0 else { return Array(repeating: 0, count: count) }

        let usable = shares.count == count && shares.allSatisfy { $0 > 0 }
            ? shares
            : Array(repeating: 1.0, count: count)
        let sum = usable.reduce(0, +)
        guard sum > 0 else { return Array(repeating: available / CGFloat(count), count: count) }

        return usable.map { available * CGFloat($0 / sum) }
    }
}
