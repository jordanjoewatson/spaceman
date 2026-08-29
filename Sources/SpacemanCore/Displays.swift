import CoreGraphics

public enum Displays {
    /// Whether `frame` sits on one of the physical displays.
    ///
    /// `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` does not mean "on the
    /// current Space". macOS arranges Spaces side by side in a single virtual
    /// coordinate plane, and the call reports windows belonging to neighbouring
    /// Spaces at their off-screen offsets — a window one Space to the right of a
    /// 1440pt display shows up near x=2955, one to the left near x=-1702.
    ///
    /// Counting those as tileable makes a Space holding one window look like it
    /// holds four, so the layout splits and then snaps back when they drop out
    /// of the list. Testing the window's centre against the union of the real
    /// displays discards them: an off-Space window's centre is nowhere near a
    /// display, while a partially dragged-off-screen window on the current Space
    /// still has its centre on one.
    public static func isOnDisplay(_ frame: CGRect, displays: [CGRect]) -> Bool {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        return displays.contains { $0.contains(centre) }
    }

    /// Which display a window belongs on for tiling.
    ///
    /// Space identity wins: during a Space slide the window's frame centre can
    /// briefly sit on another display, and an Accessibility move to that
    /// display permanently re-homes the window. Frame centre is only the
    /// fallback when the window has no Space tag.
    public static func belongs(_ window: ManagedWindow,
                               toSpace space: UInt64,
                               screen: CGRect) -> Bool {
        if !window.spaceIDs.isEmpty {
            return window.spaceIDs.contains(space)
        }
        return screen.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
    }
}
