import CoreGraphics

/// Where a bar window sits on a display.
///
/// Placement is always relative to `NSScreen.visibleFrame` (menu bar / camera
/// strip and Dock already subtracted). A positive top-bar `offsetY` moves the
/// bar up into that excluded strip — including behind a camera housing — so the
/// user can slide continuously from just below the island to the physical top
/// of the screen. The bar itself stays a straight rectangle; any hardware
/// occlusion is left to the display.
public enum BarPlacement {

    public enum Edge: Sendable {
        case top, bottom
    }

    /// The bar's frame in AppKit coordinates (origin at the bottom-left).
    public static func windowFrame(edge: Edge,
                                   visibleFrame: CGRect,
                                   thickness: CGFloat,
                                   margin: CGFloat,
                                   offsetY: CGFloat = 0) -> CGRect {
        let width = visibleFrame.width - margin * 2
        let x = visibleFrame.minX + margin
        let y: CGFloat
        switch edge {
        case .top:
            y = visibleFrame.maxY - thickness - margin + offsetY
        case .bottom:
            y = visibleFrame.minY + margin + offsetY
        }
        return CGRect(x: x, y: y, width: width, height: thickness)
    }

    /// How much of `visibleFrame`'s height the bar occupies, for tiling.
    ///
    /// Zero when the bar lives entirely in the already-excluded camera / menu
    /// bar strip, so we do not subtract the same space twice.
    public static func visibleHeightUsed(bar: CGRect, visibleFrame: CGRect) -> CGFloat {
        let overlap = bar.intersection(visibleFrame)
        guard !overlap.isNull, !overlap.isInfinite else { return 0 }
        return overlap.height
    }

    /// Distance from the visible edge to the bar's inner edge — the strip
    /// tiled windows must not use.
    ///
    /// A bar that has been offset into the desktop reserves everything from
    /// the visible edge through to that inner edge, not just its own height.
    /// A bar that sits entirely in the menu-bar / notch strip, or has been
    /// pushed out past the Dock, contributes nothing: tiling must not expand
    /// into the Dock or under the system menu bar.
    public static func visibleInset(edge: Edge, bar: CGRect, visibleFrame: CGRect) -> CGFloat {
        switch edge {
        case .top:    return max(0, visibleFrame.maxY - bar.minY)
        case .bottom: return max(0, bar.maxY - visibleFrame.minY)
        }
    }
}
