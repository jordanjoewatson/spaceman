import Carbon.HIToolbox
import SwiftUI
import PluginKit

/// The timer's preferences, under a `plugin.pomodoro.` prefix.
@MainActor
public final class PomodoroSettings: ObservableObject {

    private enum Key {
        static let work = "plugin.pomodoro.workMinutes"
        static let shortBreak = "plugin.pomodoro.shortBreakMinutes"
        static let longBreak = "plugin.pomodoro.longBreakMinutes"
        static let longBreakEvery = "plugin.pomodoro.longBreakEvery"
        static let autoAdvance = "plugin.pomodoro.autoAdvance"
        static let chime = "plugin.pomodoro.chime"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.work: 25,
            Key.shortBreak: 5,
            Key.longBreak: 15,
            Key.longBreakEvery: 4,
            Key.autoAdvance: false,
            Key.chime: true,
        ])
    }

    /// Assembled fresh each time, so an edit applies to the next phase without
    /// the timer needing to be told. `PomodoroPlan` clamps the values.
    public var plan: PomodoroPlan {
        PomodoroPlan(workMinutes: defaults.integer(forKey: Key.work),
                     shortBreakMinutes: defaults.integer(forKey: Key.shortBreak),
                     longBreakMinutes: defaults.integer(forKey: Key.longBreak),
                     longBreakEvery: defaults.integer(forKey: Key.longBreakEvery),
                     autoAdvance: defaults.bool(forKey: Key.autoAdvance))
    }

    public var chime: Bool {
        get { defaults.bool(forKey: Key.chime) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.chime) }
    }

    fileprivate func minutes(_ key: String) -> Int { defaults.integer(forKey: key) }

    fileprivate func setMinutes(_ value: Int, _ key: String) {
        objectWillChange.send()
        defaults.set(value, forKey: key)
    }

    fileprivate var autoAdvance: Bool {
        get { defaults.bool(forKey: Key.autoAdvance) }
        set { objectWillChange.send(); defaults.set(newValue, forKey: Key.autoAdvance) }
    }
}

/// A focus timer: a countdown in the bar, a window to drive it, and a chime.
///
/// The first plugin to contribute a bar module *and* a window *and* settings,
/// which is what the contract's optional fields are for.
public enum PomodoroPlugin: SpacemanPlugin {

    public static let name = "pomodoro"
    public static let displayName = "Focus Timer"
    public static let summary = "A pomodoro timer with breaks, shown in the bar "
        + "while it runs."

    @MainActor
    public static func setup(host: any PluginHost) -> PluginInstance {
        let settings = PomodoroSettings()
        let timer = PomodoroTimer(plan: { settings.plan },
                                  shouldChime: { settings.chime })

        return PluginInstance(
            commands: [
                PluginCommand(
                    id: "pomodoro.toggle",
                    keyCode: UInt32(kVK_ANSI_P),
                    modifiers: UInt32(controlKey | optionKey),
                    group: .apps,
                    desc: "Focus timer",
                    action: { host.toggleScene("pomodoro.window") }
                ),
            ],
            barModules: [
                PluginBarModule(id: "pomodoro.timer",
                                title: "Focus Timer",
                                summary: "Countdown while a focus period is running") {
                    PomodoroBarModule(timer: timer, palette: host.palette) {
                        host.showScene("pomodoro.window")
                    }
                },
            ],
            scenes: [
                // A panel, not a window: a title bar on something that exists
                // to show one number is most of its height spent on nothing.
                PluginScene(id: "pomodoro.window",
                            title: "Focus Timer",
                            style: .panel,
                            defaultSize: CGSize(width: 320, height: 300),
                            minSize: CGSize(width: 280, height: 260)) {
                    PomodoroWindow(timer: timer,
                                   palette: host.palette,
                                   plan: { settings.plan },
                                   onClose: { host.toggleScene("pomodoro.window") })
                },
            ],
            settings: PluginSettings {
                PomodoroSettingsPane(settings: settings)
            },
            // A chime firing after shutdown would outlive the app it came from.
            stop: { timer.pause() }
        )
    }
}

private struct PomodoroSettingsPane: View {
    @ObservedObject var settings: PomodoroSettings

    var body: some View {
        Form {
            Section("Durations") {
                minutesRow("Focus", "plugin.pomodoro.workMinutes", range: 1...180)
                minutesRow("Short break", "plugin.pomodoro.shortBreakMinutes", range: 1...60)
                minutesRow("Long break", "plugin.pomodoro.longBreakMinutes", range: 1...120)
            }

            Section {
                Stepper(value: Binding(
                    get: { settings.minutes("plugin.pomodoro.longBreakEvery") },
                    set: { settings.setMinutes($0, "plugin.pomodoro.longBreakEvery") }
                ), in: 1...12) {
                    Text("Long break every \(settings.minutes("plugin.pomodoro.longBreakEvery")) "
                         + "focus periods")
                }

                Toggle("Start the next phase automatically", isOn: Binding(
                    get: { settings.autoAdvance },
                    set: { settings.autoAdvance = $0 }
                ))
                .help("Otherwise a finished phase waits for you to start the next")

                Toggle("Chime when a phase ends", isOn: Binding(
                    get: { settings.chime },
                    set: { settings.chime = $0 }
                ))
            }

            Section {
                Text("Changes apply from the next phase — the one running keeps "
                     + "the length it started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func minutesRow(_ title: String, _ key: String,
                            range: ClosedRange<Int>) -> some View {
        Stepper(value: Binding(
            get: { settings.minutes(key) },
            set: { settings.setMinutes($0, key) }
        ), in: range) {
            Text("\(title): \(settings.minutes(key)) min")
        }
    }
}
