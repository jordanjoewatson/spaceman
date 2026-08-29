import Foundation

/// Which part of the cycle is running.
///
/// The Go original is a bare countdown with a chime — no breaks at all. Breaks
/// are the technique the plugin is named for, so they are modelled here; a user
/// who only wants a timer sets the break lengths to whatever suits and never
/// looks at them again.
public enum PomodoroPhase: String, Codable, Sendable, CaseIterable {
    case work, shortBreak, longBreak

    public var title: String {
        switch self {
        case .work:       return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak:  return "Long Break"
        }
    }

    public var symbolName: String {
        switch self {
        case .work:       return "brain.head.profile"
        case .shortBreak: return "cup.and.saucer"
        case .longBreak:  return "figure.walk"
        }
    }

    public var isBreak: Bool { self != .work }
}

/// How long each phase runs, and how the cycle is shaped.
public struct PomodoroPlan: Equatable, Sendable {
    public var workMinutes: Int
    public var shortBreakMinutes: Int
    public var longBreakMinutes: Int
    /// A long break replaces the short one after this many work periods.
    public var longBreakEvery: Int
    /// Whether finishing a phase starts the next one, or waits to be told.
    public var autoAdvance: Bool

    public init(workMinutes: Int = 25,
                shortBreakMinutes: Int = 5,
                longBreakMinutes: Int = 15,
                longBreakEvery: Int = 4,
                autoAdvance: Bool = false) {
        // Clamped here rather than at every call site: these come from
        // preferences, which a script can write anything into, and a zero-minute
        // phase would complete instantly and spin the cycle.
        self.workMinutes = min(max(workMinutes, 1), 180)
        self.shortBreakMinutes = min(max(shortBreakMinutes, 1), 60)
        self.longBreakMinutes = min(max(longBreakMinutes, 1), 120)
        self.longBreakEvery = min(max(longBreakEvery, 1), 12)
        self.autoAdvance = autoAdvance
    }

    public static let `default` = PomodoroPlan()

    public func duration(of phase: PomodoroPhase) -> TimeInterval {
        switch phase {
        case .work:       return TimeInterval(workMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak:  return TimeInterval(longBreakMinutes * 60)
        }
    }
}

/// Where the cycle has got to. Pure, so the progression is testable without
/// waiting 25 minutes for anything.
public struct PomodoroSession: Equatable, Sendable {

    public private(set) var phase: PomodoroPhase
    /// Work periods finished since the last reset. Drives when a long break is
    /// due, and is what the window reports as the day's tally.
    public private(set) var completedWorkPeriods: Int

    public init(phase: PomodoroPhase = .work, completedWorkPeriods: Int = 0) {
        self.phase = phase
        self.completedWorkPeriods = completedWorkPeriods
    }

    /// Move to whatever follows the current phase.
    ///
    /// Only *completing* work counts toward the tally — skipping does not — so
    /// `completed` says whether the phase ran to the end. Otherwise skipping
    /// four work periods in a row would earn a long break nobody worked for.
    public mutating func advance(plan: PomodoroPlan, completed: Bool) {
        switch phase {
        case .work:
            if completed { completedWorkPeriods += 1 }
            let due = completed
                && completedWorkPeriods > 0
                && completedWorkPeriods % plan.longBreakEvery == 0
            phase = due ? .longBreak : .shortBreak
        case .shortBreak, .longBreak:
            phase = .work
        }
    }

    public mutating func reset() {
        phase = .work
        completedWorkPeriods = 0
    }

    /// How many work periods remain before the next long break.
    public func periodsUntilLongBreak(plan: PomodoroPlan) -> Int {
        let done = completedWorkPeriods % plan.longBreakEvery
        return plan.longBreakEvery - done
    }
}

/// `M:SS`, matching the Go bar label.
///
/// A negative remainder reads as zero rather than counting up: a finished timer
/// that starts showing elapsed time looks like it is still running.
public func pomodoroClock(_ remaining: TimeInterval) -> String {
    let seconds = Int(max(remaining, 0).rounded())
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}
