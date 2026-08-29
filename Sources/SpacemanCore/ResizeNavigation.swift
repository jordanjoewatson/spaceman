import CoreGraphics

/// Finding the window whose border you are dragging.
///
/// Deliberately a different rule from `FocusNavigation`, though the gesture is
/// the same. Focus may jump to the *nearest* window in a direction whether or
/// not the two touch; resizing moves a border the two windows actually share, so
/// a candidate has to overlap on the cross axis. Reusing the focus rule would
/// happily pick a window across a gap and then move a border that does not
/// exist between them.
public enum ResizeNavigation {

    /// Absorbs the sub-pixel drift in computed frames when comparing edges.
    /// Two frames that should share a border rarely agree to the last decimal.
    public static let edgeTolerance: CGFloat = 2

    /// The window immediately adjacent to `current` in `direction`: overlapping
    /// on the cross axis, and the nearest of those on that side.
    ///
    /// nil when the window's edge in that direction is the layout boundary —
    /// which is what makes resizing toward the screen edge do nothing, rather
    /// than reaching across the layout for something to push.
    public static func neighbor(of current: CGWindowID,
                                in rects: [CGWindowID: CGRect],
                                direction: FocusDirection) -> CGWindowID? {
        guard let source = rects[current] else { return nil }

        var best: CGWindowID?
        var bestGap = CGFloat.infinity

        for (id, rect) in rects where id != current {
            let gap: CGFloat
            switch direction {
            case .left, .right:
                guard overlaps(source.minY, source.maxY, rect.minY, rect.maxY) else { continue }
                gap = direction == .right ? rect.minX - source.maxX : source.minX - rect.maxX
            case .up, .down:
                guard overlaps(source.minX, source.maxX, rect.minX, rect.maxX) else { continue }
                // AppKit coordinates: up is a larger y.
                gap = direction == .up ? rect.minY - source.maxY : source.minY - rect.maxY
            }

            // Behind us rather than toward the direction asked for.
            guard gap >= -edgeTolerance else { continue }
            // A tie goes to the lower id, so equal candidates resolve the same
            // way every time rather than following dictionary order.
            if gap < bestGap || (gap == bestGap && id < best ?? .max) {
                bestGap = gap
                best = id
            }
        }
        return best
    }

    /// Every window sharing `reference`'s horizontal band — one grid row.
    ///
    /// Rows resize as a unit: the border being dragged belongs to the whole row,
    /// so all its members must move together or the row stops being one.
    public static func rowMembers(of reference: CGRect,
                                  in rects: [CGWindowID: CGRect]) -> [CGWindowID] {
        rects
            .filter { _, rect in
                abs(rect.minY - reference.minY) < edgeTolerance
                    && abs(rect.height - reference.height) < edgeTolerance
            }
            // Sorted so the set handed to the weight transfer is deterministic.
            .keys.sorted()
    }

    /// Genuine overlap on one axis. Touching edges do not count — two windows
    /// meeting at a corner share no border to drag.
    private static func overlaps(_ a0: CGFloat, _ a1: CGFloat,
                                 _ b0: CGFloat, _ b1: CGFloat) -> Bool {
        a0 < b1 - edgeTolerance && b0 < a1 - edgeTolerance
    }
}
