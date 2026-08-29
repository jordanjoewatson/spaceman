import CoreGraphics

/// A window we are willing to tile.
///
/// `id` is the CoreGraphics window number. It is stable for the lifetime of the
/// window, which is all the reconciler needs — we never persist it.
public struct ManagedWindow: Sendable, Equatable, Identifiable {
    public let id: CGWindowID
    public let pid: pid_t
    public let ownerName: String
    /// Current frame in AppKit coordinates (bottom-left origin, global).
    public var frame: CGRect
    /// Front-to-back position as reported by the window server, 0 = frontmost.
    /// The Shortcuts mover addresses windows by this, so it must be preserved.
    public let zOrder: Int
    /// Window-server Space tags. Empty when CGS is unavailable; assignment
    /// then falls back to frame centre.
    public let spaceIDs: Set<UInt64>

    public init(id: CGWindowID, pid: pid_t, ownerName: String, frame: CGRect,
                zOrder: Int, spaceIDs: Set<UInt64> = []) {
        self.id = id
        self.pid = pid
        self.ownerName = ownerName
        self.frame = frame
        self.zOrder = zOrder
        self.spaceIDs = spaceIDs
    }
}

/// One window that is not where the layout says it should be.
public struct Move: Sendable, Equatable {
    public let window: ManagedWindow
    public let target: CGRect

    public init(window: ManagedWindow, target: CGRect) {
        self.window = window
        self.target = target
    }
}

public enum Reconciler {
    /// Windows whose actual frame differs from the layout by more than
    /// `tolerance` on any edge.
    ///
    /// The tolerance matters more than it looks: many apps refuse exact frames
    /// (size increments, minimum sizes, tabbed windows), so a strict comparison
    /// would re-issue the same rejected move on every pass and the app would
    /// thrash forever. Anything within a few points is treated as placed.
    public static func moves(
        windows: [ManagedWindow],
        targets: [CGRect],
        tolerance: CGFloat = 4
    ) -> [Move] {
        zip(windows, targets).compactMap { window, target in
            isPlaced(window.frame, target, tolerance: tolerance)
                ? nil
                : Move(window: window, target: target)
        }
    }

    public static func isPlaced(_ frame: CGRect, _ target: CGRect, tolerance: CGFloat) -> Bool {
        abs(frame.minX - target.minX) <= tolerance &&
        abs(frame.minY - target.minY) <= tolerance &&
        abs(frame.width - target.width) <= tolerance &&
        abs(frame.height - target.height) <= tolerance
    }
}
