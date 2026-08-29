import CoreGraphics

/// Per-window resize weights: how much of its row's width, and its column's
/// height, a window claims relative to its siblings.
///
/// A weight of 1 is an equal share, which is what every window starts with — so
/// an untouched layout is exactly the equal split it was before weights existed.
/// Growing a window moves weight *from its neighbour to it*, so the two swap what
/// one gains for what the other gives up and no other border moves.
///
/// Bounded at both ends: without a floor a window could be squeezed to nothing
/// and become unclickable, and without a ceiling one could crowd every sibling
/// off the screen.
public struct ResizeWeights: Equatable, Sendable {

    /// The smallest share a window may be reduced to, and the largest it may
    /// claim — both relative to an equal share of 1.
    public static let minimum: Double = 0.3
    public static let maximum: Double = 3.0
    /// How much weight one press moves.
    public static let step: Double = 0.15

    private var widths: [CGWindowID: Double] = [:]
    private var heights: [CGWindowID: Double] = [:]

    public init() {}

    public func width(_ id: CGWindowID) -> Double { widths[id] ?? 1 }
    public func height(_ id: CGWindowID) -> Double { heights[id] ?? 1 }

    public var isEmpty: Bool { widths.isEmpty && heights.isEmpty }

    /// Move width from `donor` to `recipient`.
    ///
    /// The amount is whatever the tighter of the two limits allows, so a press
    /// near a limit still does something rather than nothing. Returns false only
    /// when neither can move at all — which lets the caller skip a re-tile that
    /// would change no frame.
    @discardableResult
    public mutating func growWidth(of recipient: CGWindowID,
                                   from donor: CGWindowID) -> Bool {
        guard recipient != donor else { return false }
        let amount = allowance(gaining: [width(recipient)], giving: [width(donor)])
        guard amount > 0 else { return false }
        widths[recipient] = width(recipient) + amount
        widths[donor] = width(donor) - amount
        return true
    }

    /// Move height from one set of windows to another.
    ///
    /// Sets rather than single windows because a grid row resizes as a unit: the
    /// border being dragged is the whole row's, so every member has to move by
    /// the same amount or the row stops being a row.
    @discardableResult
    public mutating func growHeight(of recipients: [CGWindowID],
                                    from donors: [CGWindowID]) -> Bool {
        guard !recipients.isEmpty, !donors.isEmpty,
              Set(recipients).isDisjoint(with: Set(donors)) else { return false }

        let amount = allowance(gaining: recipients.map(height),
                               giving: donors.map(height))
        guard amount > 0 else { return false }

        for id in recipients { heights[id] = height(id) + amount }
        for id in donors { heights[id] = height(id) - amount }
        return true
    }

    /// The largest step that keeps every gainer under the ceiling and every
    /// giver above the floor.
    private func allowance(gaining: [Double], giving: [Double]) -> Double {
        var amount = Self.step
        for value in gaining { amount = min(amount, Self.maximum - value) }
        for value in giving { amount = min(amount, value - Self.minimum) }
        return amount
    }

    /// Back to an equal share for everything.
    public mutating func reset() {
        widths.removeAll()
        heights.removeAll()
    }

    /// Forget windows that have closed, so a reused window id never inherits a
    /// dead window's weights.
    public mutating func retain(only live: Set<CGWindowID>) {
        widths = widths.filter { live.contains($0.key) }
        heights = heights.filter { live.contains($0.key) }
    }
}

/// Weights arranged by slot, as the layout engine wants them.
///
/// The engine works in slots, not window ids — it is handed a count and returns
/// that many frames — so the controller translates on the way in.
public struct LayoutWeights: Equatable, Sendable {
    public var widths: [Double]
    public var heights: [Double]

    public init(widths: [Double], heights: [Double]) {
        self.widths = widths
        self.heights = heights
    }

    /// Every slot an equal share.
    public static func equal(count: Int) -> LayoutWeights {
        LayoutWeights(widths: Array(repeating: 1, count: count),
                      heights: Array(repeating: 1, count: count))
    }

    /// True when nothing has been resized, so callers can take the plain
    /// equal-split path and stay bit-identical to the unweighted layout.
    public var isUniform: Bool {
        widths.allSatisfy { $0 == 1 } && heights.allSatisfy { $0 == 1 }
    }

    func width(_ slot: Int) -> Double { slot < widths.count ? widths[slot] : 1 }
    func height(_ slot: Int) -> Double { slot < heights.count ? heights[slot] : 1 }
}
