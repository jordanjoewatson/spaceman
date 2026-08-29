import AppKit
import Foundation

/// The running timer: the session, plus a deadline and a tick.
///
/// Counts down against a *deadline* rather than decrementing a counter, so it
/// stays right across a missed tick, a busy main thread, or the machine sleeping
/// — none of which a decrementing counter survives.
@MainActor
public final class PomodoroTimer: ObservableObject {

    @Published public private(set) var session = PomodoroSession()
    @Published public private(set) var isRunning = false
    /// Seconds left in the current phase, whether running or paused.
    @Published public private(set) var remaining: TimeInterval

    /// Read fresh on every use so a Settings change applies to the next phase
    /// without the timer having to be told.
    private let plan: () -> PomodoroPlan
    private let shouldChime: () -> Bool

    private var deadline: Date?
    private var ticker: Timer?

    public init(plan: @escaping () -> PomodoroPlan,
                shouldChime: @escaping () -> Bool) {
        self.plan = plan
        self.shouldChime = shouldChime
        self.remaining = plan().duration(of: .work)
    }

    deinit {
        ticker?.invalidate()
    }

    /// Nothing running, and the current phase untouched.
    ///
    /// The bar module hides on this: an idle timer has nothing to report, but a
    /// *paused* one part-way through is something you started and have not
    /// finished, which is worth showing.
    public var isIdle: Bool {
        !isRunning
            && session.completedWorkPeriods == 0
            && remaining >= plan().duration(of: session.phase)
    }

    // MARK: - Controls

    public func toggle() {
        isRunning ? pause() : start()
    }

    public func start() {
        guard !isRunning else { return }
        // A phase already at zero restarts rather than finishing instantly.
        if remaining <= 0 { remaining = plan().duration(of: session.phase) }
        deadline = Date().addingTimeInterval(remaining)
        isRunning = true
        startTicking()
    }

    public func pause() {
        guard isRunning else { return }
        remaining = remainingFromDeadline()
        deadline = nil
        isRunning = false
        stopTicking()
    }

    /// Back to the start of the current phase, still stopped.
    public func resetPhase() {
        stopTicking()
        isRunning = false
        deadline = nil
        remaining = plan().duration(of: session.phase)
    }

    /// Abandon the whole cycle: back to a fresh work period with no tally.
    public func resetAll() {
        session.reset()
        resetPhase()
    }

    /// Move on without finishing. Deliberately does not count toward the tally
    /// or toward earning a long break.
    public func skip() {
        advance(completed: false)
    }

    // MARK: - Ticking

    private func startTicking() {
        stopTicking()
        // 1 Hz is all a M:SS display needs; the deadline carries the precision.
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }

    private func tick() {
        remaining = remainingFromDeadline()
        guard remaining <= 0 else { return }
        if shouldChime() { PomodoroChime.play() }
        advance(completed: true)
    }

    private func remainingFromDeadline() -> TimeInterval {
        guard let deadline else { return remaining }
        return max(deadline.timeIntervalSinceNow, 0)
    }

    private func advance(completed: Bool) {
        let plan = plan()
        session.advance(plan: plan, completed: completed)
        remaining = plan.duration(of: session.phase)

        if plan.autoAdvance {
            deadline = Date().addingTimeInterval(remaining)
            isRunning = true
            startTicking()
        } else {
            deadline = nil
            isRunning = false
            stopTicking()
        }
    }
}

/// The end-of-phase sound.
///
/// A system sound rather than a bundled asset: it already matches the user's
/// alert volume and output device, and it means the plugin ships no audio.
enum PomodoroChime {
    static func play() {
        // Falls back to the system beep if the named sound is ever missing,
        // rather than a phase ending in silence.
        if let sound = NSSound(named: NSSound.Name("Glass")) {
            sound.play()
        } else {
            NSSound.beep()
        }
    }
}
