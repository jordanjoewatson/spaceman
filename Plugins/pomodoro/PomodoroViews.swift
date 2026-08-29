import SwiftUI
import PluginKit

/// The timer window: the countdown, the controls, and where you are in the cycle.
struct PomodoroWindow: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var palette: PluginPalette
    let plan: () -> PomodoroPlan
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            phaseHeader
            countdown
            controls
            cycleFooter
        }
        .padding(22)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The panel is borderless, so the content is the whole surface — it has
        // to paint its own background or the window is a floating hole.
        .background(palette.color(.background))
    }

    /// The panel has no title bar, so the phase name doubles as its heading and
    /// carries the only visible close affordance.
    private var phaseHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: timer.session.phase.symbolName)
            Text(timer.session.phase.title)
                .font(.title3.weight(.medium))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(palette.color(.muted))
            }
            .buttonStyle(.plain)
            .help("Close (Escape)")
        }
        .foregroundStyle(phaseColor)
    }

    private var countdown: some View {
        Text(pomodoroClock(timer.remaining))
            // Monospaced digits so the layout doesn't jitter every second as
            // glyph widths change.
            .font(.system(size: 72, weight: .light, design: .rounded))
            .monospacedDigit()
            .foregroundStyle(palette.color(.text))
            .contentTransition(.numericText())
            .animation(.default, value: timer.remaining)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Button(timer.isRunning ? "Pause" : "Start") { timer.toggle() }
                .keyboardShortcut(.space, modifiers: [])
                .buttonStyle(.borderedProminent)

            Button("Reset") { timer.resetPhase() }
            Button("Skip") { timer.skip() }
                .help("Move to the next phase without counting this one")
        }
    }

    private var cycleFooter: some View {
        VStack(spacing: 6) {
            // One dot per work period in the cycle, filled as they are earned —
            // the tally at a glance, without a number to read.
            HStack(spacing: 5) {
                let total = plan().longBreakEvery
                let done = timer.session.completedWorkPeriods % total
                ForEach(0..<total, id: \.self) { index in
                    Circle()
                        .fill(index < done ? palette.color(.accent) : palette.color(.muted))
                        .opacity(index < done ? 1 : 0.35)
                        .frame(width: 7, height: 7)
                }
            }

            Text(footerText)
                .font(.caption)
                .foregroundStyle(palette.color(.muted))
        }
    }

    private var footerText: String {
        let completed = timer.session.completedWorkPeriods
        let remaining = timer.session.periodsUntilLongBreak(plan: plan())
        let tally = completed == 1 ? "1 focus period" : "\(completed) focus periods"
        return "\(tally) · long break in \(remaining)"
    }

    private var phaseColor: Color {
        timer.session.phase.isBreak ? palette.color(.good) : palette.color(.accent)
    }
}

/// The bar module: the countdown while something is running.
///
/// Silent when idle. A bar module that always shows something trains you to stop
/// reading it, and an idle timer has nothing to say.
struct PomodoroBarModule: View {
    @ObservedObject var timer: PomodoroTimer
    @ObservedObject var palette: PluginPalette
    let onOpen: () -> Void

    var body: some View {
        if !timer.isIdle {
            Button(action: onOpen) {
                HStack(spacing: 5) {
                    Image(systemName: timer.session.phase.symbolName)
                    Text(pomodoroClock(timer.remaining)).monospacedDigit()
                }
                .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .help("\(timer.session.phase.title) — \(timer.isRunning ? "running" : "paused")")
        }
    }

    /// A paused timer mid-phase still shows, dimmed: it is a thing you started
    /// and have not finished, which is worth a reminder.
    private var tint: Color {
        if !timer.isRunning { return palette.color(.muted) }
        return timer.session.phase.isBreak ? palette.color(.good) : palette.color(.accent)
    }
}
