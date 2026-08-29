import CoreGraphics

/// A spatial focus-movement direction (the Go version's `store.Direction`).
public enum FocusDirection: Sendable {
    case left, right, up, down
}

/// Spatial focus navigation over the current layout, ported from the Go
/// version's `FocusDir`: of the windows lying in the requested direction,
/// prefer the nearest along the primary axis and penalise cross-axis drift.
///
/// Everything here is AppKit geometry (bottom-left origin, y up), so "up" is a
/// *positive* dy — the Go code runs in CG coordinates where up is negative.
public enum FocusNavigation {

    /// The window nearest `current` in `direction`, or nil at the layout edge.
    /// `rects` are the windows' target frames — the layout's idea of where
    /// things are, which stays true while a move animation is still gliding.
    public static func neighbor(of current: CGWindowID, in rects: [CGWindowID: CGRect],
                                direction: FocusDirection) -> CGWindowID? {
        guard let cur = rects[current] else { return nil }
        let cx = cur.midX, cy = cur.midY

        var best: CGWindowID?
        var bestScore = CGFloat.infinity
        for (id, rect) in rects where id != current {
            let dx = rect.midX - cx, dy = rect.midY - cy
            // Must lie in the requested direction, with a point of slack.
            switch direction {
            case .left:  guard dx < -1 else { continue }
            case .right: guard dx > 1  else { continue }
            case .up:    guard dy > 1  else { continue }
            case .down:  guard dy < -1 else { continue }
            }
            let score: CGFloat
            switch direction {
            case .left, .right: score = abs(dx) + 2 * abs(dy)
            case .up, .down:    score = abs(dy) + 2 * abs(dx)
            }
            // A tie goes to the lower id, so equal candidates pick the same
            // window every time (dictionary order is nobody's friend).
            if score < bestScore || (score == bestScore && id < best ?? .max) {
                bestScore = score
                best = id
            }
        }
        return best
    }
}
