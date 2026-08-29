import Testing
import CoreGraphics
@testable import SpacemanCore

@Suite("PlacementTracker")
struct PlacementTrackerTests {

    private let target = CGRect(x: 794, y: 34, width: 637, height: 412)
    /// Shape observed from System Settings, which refuses to shrink below its
    /// minimum size.
    private let refusedResult = CGRect(x: 794, y: 34, width: 723, height: 470)

    private func window(_ id: CGWindowID, _ frame: CGRect) -> ManagedWindow {
        ManagedWindow(id: id, pid: 1, ownerName: "Test", frame: frame, zOrder: 0)
    }

    @Test("nothing is refused before anything has been asked")
    func startsClean() {
        let tracker = PlacementTracker()
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("a window that reaches its target is not marked refused")
    func successfulMoveIsNotRefused() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, target)], tolerance: 4)
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("a window that ignores its target is refused once it has stopped")
    func refusedMoveIsRemembered() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        // First pass: off target, but we have no history — not yet judged.
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        // Second pass: unchanged, so it has settled somewhere it prefers.
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        #expect(tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("a window still travelling is never judged refused")
    func inFlightWindowIsNotRefused() {
        // The bug this guards: an animation takes ~140ms and the app applies the
        // frame asynchronously after that, so a window is legitimately off
        // target for several passes. Judging it early froze the layout
        // half-finished with every window marked unplaceable.
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        for step in 1...5 {
            let travelling = CGRect(x: CGFloat(step) * 100, y: 34, width: 700, height: 500)
            tracker.observe(windows: [window(1, travelling)], tolerance: 4)
            #expect(!tracker.isRefused(1, target: target, tolerance: 4),
                    "must not be refused while still moving (step \(step))")
        }
    }

    @Test("a window that arrives late is not refused")
    func lateArrivalIsAccepted() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, CGRect(x: 400, y: 34, width: 700, height: 500))],
                        tolerance: 4)
        tracker.observe(windows: [window(1, target)], tolerance: 4)
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("a refusal applies only to that target, not to the window")
    func refusalIsPerTarget() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)

        // Changing layout mode or master ratio yields a different target, which
        // the window may well accept — it must be tried.
        let different = CGRect(x: 0, y: 0, width: 900, height: 800)
        #expect(!tracker.isRefused(1, target: different, tolerance: 4))
    }

    @Test("a refusal applies only to that window")
    func refusalIsPerWindow() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        #expect(!tracker.isRefused(2, target: target, tolerance: 4))
    }

    @Test("landing within tolerance counts as success")
    func toleranceCountsAsPlaced() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        let nearlyThere = target.offsetBy(dx: 2, dy: 1)
        tracker.observe(windows: [window(1, nearlyThere)], tolerance: 4)
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("observe is idempotent and does not re-judge a cleared request")
    func observeClearsPending() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, target)], tolerance: 4)
        // Second observe with a displaced frame must not invent a refusal: no
        // request was outstanding.
        tracker.observe(windows: [window(1, .zero)], tolerance: 4)
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("a window that vanished mid-pass is not judged")
    func missingWindowIsNotJudged() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [], tolerance: 4)
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("closed windows are forgotten so the map cannot grow unbounded")
    func retainDropsDeadWindows() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        #expect(tracker.isRefused(1, target: target, tolerance: 4))

        tracker.retain(only: [99])
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }

    @Test("reset clears refusals so an explicit re-tile really retries")
    func resetClears() {
        var tracker = PlacementTracker()
        tracker.record([Move(window: window(1, .zero), target: target)])
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        tracker.observe(windows: [window(1, refusedResult)], tolerance: 4)
        tracker.reset()
        #expect(!tracker.isRefused(1, target: target, tolerance: 4))
    }
}
