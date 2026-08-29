import CoreGraphics

/// Decides whether the top and bottom bars should be out of the way, based on
/// where the pointer is.
///
/// Both edges participate, and each display is evaluated separately so a pointer
/// at the top of one screen only moves that screen's top bar.
///
/// Pure so the hysteresis can be tested without a mouse: the interesting part is
/// not "is the pointer at the edge" but "does this flap when it sits exactly on
/// the boundary".
public struct EdgeReveal: Sendable {

    /// Distance from the edge at which a bar gets out of the way. Matches the
    /// band macOS itself uses to reveal an auto-hidden menu bar or Dock closely
    /// enough that the two feel like one gesture.
    public static let enterZone: CGFloat = 4
    /// The pointer must retreat this much further before the bar returns.
    /// Without the gap, a pointer resting on the boundary would toggle the bar
    /// on every sample.
    public static let exitZone: CGFloat = 32

    public private(set) var topHidden = false
    public private(set) var bottomHidden = false

    public init() {}

    /// Update from a pointer position. `screen` is the full display frame in
    /// AppKit coordinates (bottom-left origin).
    ///
    /// Returns true when either bar changed state, so callers can skip work.
    @discardableResult
    public mutating func update(pointer: CGPoint, screen: CGRect) -> Bool {
        let wasTop = topHidden
        let wasBottom = bottomHidden

        // Off this display entirely: restore both rather than leaving a bar
        // stuck hidden on a screen the pointer has left.
        guard screen.insetBy(dx: -1, dy: -1).contains(pointer) else {
            topHidden = false
            bottomHidden = false
            return wasTop || wasBottom
        }

        topHidden = hysteresis(current: topHidden, distance: screen.maxY - pointer.y)
        bottomHidden = hysteresis(current: bottomHidden, distance: pointer.y - screen.minY)

        return topHidden != wasTop || bottomHidden != wasBottom
    }

    private func hysteresis(current: Bool, distance: CGFloat) -> Bool {
        current ? distance < Self.exitZone : distance <= Self.enterZone
    }
}
