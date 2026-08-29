import CoreGraphics

/// Which window holds which tiled slot, for one Space.
///
/// Slots are assigned by *position in this list*, not by window id or z-order.
/// Without it, merely focusing a window would promote it to master and reshuffle
/// everything — and returning to a Space with a different window focused would
/// move every window on it.
///
/// The Go version reaches the same end differently, keeping a map of override
/// keys consulted alongside the raw window id (`store.orderKey`). An explicit
/// list is simpler and makes swapping two windows exactly what it sounds like:
/// exchanging two elements.
public struct SlotOrder: Equatable, Sendable {

    private(set) var ids: [CGWindowID]

    public init(_ ids: [CGWindowID] = []) {
        self.ids = ids
    }

    /// Bring the order in line with the windows actually present, and report the
    /// slot order to lay out.
    ///
    /// Closed windows are dropped and their slots close up; unknown windows are
    /// appended in the order the window server reported them, so a newly opened
    /// window lands predictably at the end rather than in the middle.
    public mutating func reconcile(present: [CGWindowID]) -> [CGWindowID] {
        let live = Set(present)
        ids.removeAll { !live.contains($0) }

        let known = Set(ids)
        for id in present where !known.contains(id) {
            ids.append(id)
        }
        return ids
    }

    /// Exchange the slots of two windows.
    ///
    /// Returns false when the swap is meaningless — the same window twice, or
    /// one that holds no slot here — so callers can skip the re-tile rather than
    /// issuing a pass that moves nothing.
    @discardableResult
    public mutating func swap(_ a: CGWindowID, _ b: CGWindowID) -> Bool {
        guard a != b,
              let first = ids.firstIndex(of: a),
              let second = ids.firstIndex(of: b) else { return false }
        ids.swapAt(first, second)
        return true
    }

    public func slot(of id: CGWindowID) -> Int? {
        ids.firstIndex(of: id)
    }

    public var isEmpty: Bool { ids.isEmpty }
}
