import Testing
import Foundation
@testable import PomodoroPlugin

@Suite("Pomodoro plan")
struct PomodoroPlanTests {

    @Test("durations come from the plan")
    func durations() {
        let plan = PomodoroPlan(workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15)
        #expect(plan.duration(of: .work) == 1500)
        #expect(plan.duration(of: .shortBreak) == 300)
        #expect(plan.duration(of: .longBreak) == 900)
    }

    @Test("absurd values are clamped rather than accepted")
    func clampsValues() {
        // These arrive from preferences, which a script can write anything into.
        // A zero-minute phase would complete instantly and spin the cycle.
        let plan = PomodoroPlan(workMinutes: 0, shortBreakMinutes: -5,
                                longBreakMinutes: 9999, longBreakEvery: 0)
        #expect(plan.workMinutes == 1)
        #expect(plan.shortBreakMinutes == 1)
        #expect(plan.longBreakMinutes == 120)
        #expect(plan.longBreakEvery == 1)
    }
}

@Suite("Pomodoro session")
struct PomodoroSessionTests {

    private let plan = PomodoroPlan(longBreakEvery: 4)

    @Test("starts on a focus period with nothing counted")
    func startsFresh() {
        let session = PomodoroSession()
        #expect(session.phase == .work)
        #expect(session.completedWorkPeriods == 0)
    }

    @Test("finishing work earns a short break and counts")
    func workThenShortBreak() {
        var session = PomodoroSession()
        session.advance(plan: plan, completed: true)
        #expect(session.phase == .shortBreak)
        #expect(session.completedWorkPeriods == 1)
    }

    @Test("a break always returns to work without counting")
    func breakThenWork() {
        var session = PomodoroSession(phase: .shortBreak, completedWorkPeriods: 1)
        session.advance(plan: plan, completed: true)
        #expect(session.phase == .work)
        #expect(session.completedWorkPeriods == 1, "breaks are not work")
    }

    @Test("the fourth finished period earns a long break")
    func longBreakOnInterval() {
        var session = PomodoroSession()
        for period in 1...4 {
            session.advance(plan: plan, completed: true)     // finish work
            let expected: PomodoroPhase = period == 4 ? .longBreak : .shortBreak
            #expect(session.phase == expected, "after period \(period)")
            session.advance(plan: plan, completed: true)     // finish the break
        }
        #expect(session.completedWorkPeriods == 4)
    }

    @Test("the cycle repeats after a long break")
    func cycleRepeats() {
        var session = PomodoroSession(phase: .work, completedWorkPeriods: 4)
        session.advance(plan: plan, completed: true)
        #expect(session.completedWorkPeriods == 5)
        #expect(session.phase == .shortBreak, "5 is not a multiple of 4")
    }

    @Test("skipping work does not count toward the tally")
    func skippingDoesNotCount() {
        // Otherwise skipping four periods in a row earns a long break nobody
        // worked for.
        var session = PomodoroSession()
        for _ in 0..<4 {
            session.advance(plan: plan, completed: false)    // skip work
            session.advance(plan: plan, completed: false)    // skip the break
        }
        #expect(session.completedWorkPeriods == 0)
        #expect(session.phase == .work)
    }

    @Test("skipping never earns a long break")
    func skippingNeverEarnsLongBreak() {
        var session = PomodoroSession(phase: .work, completedWorkPeriods: 3)
        session.advance(plan: plan, completed: false)
        #expect(session.phase == .shortBreak,
                "a skipped fourth period must not become a long break")
    }

    @Test("an interval of one makes every break long")
    func intervalOfOne() {
        let plan = PomodoroPlan(longBreakEvery: 1)
        var session = PomodoroSession()
        session.advance(plan: plan, completed: true)
        #expect(session.phase == .longBreak)
    }

    @Test("reset clears the phase and the tally")
    func reset() {
        var session = PomodoroSession(phase: .longBreak, completedWorkPeriods: 8)
        session.reset()
        #expect(session.phase == .work)
        #expect(session.completedWorkPeriods == 0)
    }

    @Test("the countdown to a long break wraps with the cycle")
    func periodsUntilLongBreak() {
        #expect(PomodoroSession(completedWorkPeriods: 0).periodsUntilLongBreak(plan: plan) == 4)
        #expect(PomodoroSession(completedWorkPeriods: 1).periodsUntilLongBreak(plan: plan) == 3)
        #expect(PomodoroSession(completedWorkPeriods: 3).periodsUntilLongBreak(plan: plan) == 1)
        #expect(PomodoroSession(completedWorkPeriods: 4).periodsUntilLongBreak(plan: plan) == 4,
                "back to a full cycle, not zero")
    }
}

@Suite("Pomodoro clock")
struct PomodoroClockTests {

    @Test("formats as M:SS")
    func format() {
        #expect(pomodoroClock(1500) == "25:00")
        #expect(pomodoroClock(65) == "1:05")
        #expect(pomodoroClock(9) == "0:09")
    }

    @Test("a finished timer reads zero rather than counting up")
    func neverNegative() {
        // A deadline in the past yields a negative remainder; showing elapsed
        // time would make a finished timer look like it is still running.
        #expect(pomodoroClock(0) == "0:00")
        #expect(pomodoroClock(-30) == "0:00")
    }

    @Test("seconds round rather than truncate toward the wrong second")
    func rounds() {
        #expect(pomodoroClock(59.6) == "1:00")
    }
}
