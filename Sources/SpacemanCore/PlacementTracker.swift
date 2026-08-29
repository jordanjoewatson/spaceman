import CoreGraphics

/// Remembers which targets a window has already refused.
///
/// Not every window can be put where the layout wants it. System Settings has a
/// minimum size, terminals resize in character-cell increments, and some dialogs
/// are fixed. Asking such a window for an impossible frame fails silently, so
/// the next pass sees it out of place and asks again — forever. With animation
/// enabled that becomes a continuous 140ms animation loop, which is precisely
/// what "there's a lag" feels like from the outside.
///
/// The rule: ask once, check the result on the following pass, and if the window
/// did not arrive, stop asking *for that target*. A different target — because
/// the layout mode, master ratio or window count changed — is tried afresh,
/// since the window may well accept it.
public struct PlacementTracker: Sendable {

    /// Targets we have asked for and not yet judged.
    private var pending: [CGWindowID: CGRect] = [:]
    /// Targets a window demonstrably will not accept.
    private var refused: [CGWindowID: CGRect] = [:]
    /// Where each window was on the previous pass, used to tell "still moving"
    /// from "stopped somewhere else".
    private var lastSeen: [CGWindowID: CGRect] = [:]

    public init() {}

    /// Judge outstanding requests against where windows actually are.
    /// Call once per pass, before deciding what to move.
    ///
    /// A window is only judged once it has **stopped moving**. Windows do not
    /// arrive instantly — an animation is in flight for ~140ms and the app
    /// applies the frame asynchronously after that — so "not at its target yet"
    /// is the normal case for several passes. Treating that as a refusal marks
    /// every window unplaceable the moment it starts moving, and the layout
    /// freezes half-finished. Only a window that is off-target *and* has not
    /// changed since the last pass has genuinely declined.
    public mutating func observe(windows: [ManagedWindow], tolerance: CGFloat) {
        let frames = Dictionary(windows.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        defer { lastSeen = frames }

        guard !pending.isEmpty else { return }

        for (id, target) in pending {
            guard let frame = frames[id] else {
                pending[id] = nil   // window closed mid-flight
                continue
            }

            if Reconciler.isPlaced(frame, target, tolerance: tolerance) {
                pending[id] = nil   // arrived
                continue
            }

            // Off target. Settled there, or still travelling?
            if let previous = lastSeen[id],
               Reconciler.isPlaced(frame, previous, tolerance: tolerance) {
                refused[id] = target
                pending[id] = nil
            }
            // Otherwise still moving — keep the request open and judge later.
        }
    }

    /// Whether this window has already declined this target.
    public func isRefused(_ id: CGWindowID, target: CGRect, tolerance: CGFloat) -> Bool {
        guard let refusedTarget = refused[id] else { return false }
        return Reconciler.isPlaced(refusedTarget, target, tolerance: tolerance)
    }

    /// Note the requests made this pass so the next one can judge them.
    public mutating func record(_ moves: [Move]) {
        for move in moves { pending[move.window.id] = move.target }
    }

    /// Forget everything about windows that no longer exist.
    public mutating func retain(only live: Set<CGWindowID>) {
        pending = pending.filter { live.contains($0.key) }
        refused = refused.filter { live.contains($0.key) }
        lastSeen = lastSeen.filter { live.contains($0.key) }
    }

    /// Drop all refusals — used when the user explicitly asks for a re-tile, so
    /// an intentional command always gets a genuine attempt.
    public mutating func reset() {
        pending.removeAll()
        refused.removeAll()
        lastSeen.removeAll()
    }
}
