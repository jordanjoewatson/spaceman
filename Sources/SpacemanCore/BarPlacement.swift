import CoreGraphics

/// Where a bar window sits on a display, including the camera housing on a
/// notched MacBook.
///
/// `NSScreen.visibleFrame` already excludes the menu bar and Dock. On a display
/// with a camera housing it also excludes that whole top strip, so a bar placed
/// on `visibleFrame` sits *below* the notch and leaves the ears on either side
/// of it empty. Flush top bars therefore pin to `screen.frame` and grow to the
/// safe-area height so those ears are filled; content is laid out around the
/// housing by the renderer using the auxiliary areas.
public enum BarPlacement {

    public enum Edge: Sendable {
        case top, bottom
    }

    /// Window height. A flush top bar on a notched display is at least as tall
    /// as the camera strip; otherwise the preset height is used as-is.
    public static func thickness(edge: Edge,
                                 requested: CGFloat,
                                 floating: Bool,
                                 safeAreaTop: CGFloat) -> CGFloat {
        if edge == .top, !floating, safeAreaTop > 0 {
            return max(requested, safeAreaTop)
        }
        return requested
    }

    /// The bar's frame in AppKit coordinates (origin at the bottom-left).
    public static func windowFrame(edge: Edge,
                                   screenFrame: CGRect,
                                   visibleFrame: CGRect,
                                   safeAreaTop: CGFloat,
                                   thickness: CGFloat,
                                   margin: CGFloat,
                                   offsetY: CGFloat = 0) -> CGRect {
        let width: CGFloat
        let x: CGFloat
        let y: CGFloat
        switch edge {
        case .top:
            if margin == 0, safeAreaTop > 0 {
                // Physical top, full display width — the same strip the system
                // menu bar uses, including the ears either side of the camera.
                x = screenFrame.minX
                y = screenFrame.maxY - thickness + offsetY
                width = screenFrame.width
            } else {
                x = visibleFrame.minX + margin
                y = visibleFrame.maxY - thickness - margin + offsetY
                width = visibleFrame.width - margin * 2
            }
        case .bottom:
            x = visibleFrame.minX + margin
            y = visibleFrame.minY + margin + offsetY
            width = visibleFrame.width - margin * 2
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

    /// The camera housing in bar-local coordinates, or nil when there is none.
    ///
    /// `leftAuxMaxX` / `rightAuxMinX` are the screen-coordinate edges of
    /// `NSScreen.auxiliaryTopLeftArea` and `auxiliaryTopRightArea`.
    public static func notchCutout(barMinX: CGFloat,
                                   leftAuxMaxX: CGFloat,
                                   rightAuxMinX: CGFloat) -> CGRect? {
        let width = rightAuxMinX - leftAuxMaxX
        guard width > 1 else { return nil }
        return CGRect(x: leftAuxMaxX - barMinX, y: 0, width: width, height: 0)
    }
}
