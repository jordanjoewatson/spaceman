import AppKit
import SpacemanCore

/// Drives a set of window moves from their current frames to their targets over
/// a short duration.
///
/// Only usable with a mover that can apply frames at display rate — see
/// `WindowMover.supportsAnimation`. The Shortcuts path cannot: every frame would
/// be an Apple Event round-trip, so animating there would be slower *and* look
/// worse than snapping.
@MainActor
final class Animator {

    /// How long a move takes. 140ms by default — long enough to read as motion,
    /// short enough that it never delays the user's next action — and settable
    /// from `animation.duration`.
    var duration: TimeInterval = Defaults.animationDuration.fallback

    /// 60 Hz. Each frame costs one position + one size write per window, so the
    /// IPC load scales with window count; doubling to 120 Hz buys almost nothing
    /// visually and doubles that cost.
    private static let frameRate: TimeInterval = 1.0 / 60.0

    private var timer: Timer?
    private(set) var isRunning = false

    /// Animate `moves`, calling `apply` with interpolated frames.
    ///
    /// `completion` always runs — on natural end or on cancellation — so callers
    /// can rely on it to lift whatever suspension they put in place.
    func run(
        moves: [Move],
        applyFrame: @escaping ([Move]) -> Void,
        apply: @escaping ([Move]) -> Void,
        completion: @escaping () -> Void
    ) {
        cancel()
        guard !moves.isEmpty else { completion(); return }

        let start = Date()
        // Read once: a duration changed from Settings mid-flight would otherwise
        // make the easing jump.
        let duration = self.duration
        isRunning = true
        var frameCount = 0
        var frameTimeTotal: TimeInterval = 0

        let timer = Timer(timeInterval: Self.frameRate, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }

                let elapsed = Date().timeIntervalSince(start)
                let progress = min(elapsed / duration, 1.0)
                let eased = Easing.easeOutCubic(CGFloat(progress))

                let frame = moves.map { move in
                    Move(window: move.window,
                         target: move.window.frame.interpolated(to: move.target, progress: eased))
                }
                let t0 = CFAbsoluteTimeGetCurrent()
                applyFrame(frame)
                frameTimeTotal += CFAbsoluteTimeGetCurrent() - t0
                frameCount += 1

                guard progress >= 1.0 else { return }
                // Land exactly on the target: the eased value reaches 1.0 but
                // the interpolation can still leave sub-point error, and the
                // reconciler would otherwise see a near-miss next pass.
                apply(moves)
                Log.debug(String(format: "animated %d window(s): %d frames, %.2fms/frame",
                                 moves.count, frameCount,
                                 frameCount > 0 ? frameTimeTotal / Double(frameCount) * 1000 : 0))
                self.finish(completion)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    private func finish(_ completion: () -> Void) {
        cancel()
        completion()
    }
}
