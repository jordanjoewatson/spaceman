import CoreGraphics

public enum Easing {
    /// Fast out of the gate, gently into place. Chosen because a tiling move is
    /// a *correction* — the user wants to see where the window ended up, not
    /// watch it travel — so most of the distance is covered in the first third
    /// of the duration.
    public static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let clamped = min(max(t, 0), 1)
        let inverted = 1 - clamped
        return 1 - inverted * inverted * inverted
    }
}

extension CGRect {
    /// Linear blend towards `target`, edge by edge.
    ///
    /// Interpolating origin and size independently (rather than, say, centre and
    /// scale) keeps every intermediate rect a valid window frame, which matters
    /// because each one is handed straight to the window server.
    public func interpolated(to target: CGRect, progress: CGFloat) -> CGRect {
        let t = min(max(progress, 0), 1)
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * t }
        return CGRect(
            x: lerp(minX, target.minX),
            y: lerp(minY, target.minY),
            width: lerp(width, target.width),
            height: lerp(height, target.height)
        )
    }
}
