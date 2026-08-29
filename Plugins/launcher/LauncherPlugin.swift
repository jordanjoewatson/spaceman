import Carbon.HIToolbox
import SwiftUI
import PluginKit

/// The launcher's preferences.
///
/// `UserDefaults` under a `plugin.launcher.` prefix — the same store the rest of
/// the app uses, so there is no file to parse or watch.
@MainActor
public final class LauncherSettings: ObservableObject {

    private enum Key {
        static let maxResults = "plugin.launcher.maxResults"
        static let providers = "plugin.launcher.providers"
        static let useFrecency = "plugin.launcher.useFrecency"
    }

    /// Which result kinds the launcher offers. Turning one off removes its
    /// provider entirely rather than filtering afterwards, so the work is not
    /// done either.
    public enum Provider: String, CaseIterable, Sendable {
        case calculator, apps, windows, commands

        public var title: String {
            switch self {
            case .calculator: return "Calculator"
            case .apps:       return "Applications"
            case .windows:    return "Open Windows"
            case .commands:   return "Window Commands"
            }
        }
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.maxResults: 8,
            Key.useFrecency: true,
            Key.providers: Provider.allCases.map(\.rawValue),
        ])
    }

    public var maxResults: Int {
        get { defaults.integer(forKey: Key.maxResults) }
        set {
            objectWillChange.send()
            defaults.set(min(max(newValue, 3), 20), forKey: Key.maxResults)
        }
    }

    /// Whether frequently-used results are promoted.
    public var useFrecency: Bool {
        get { defaults.bool(forKey: Key.useFrecency) }
        set {
            objectWillChange.send()
            defaults.set(newValue, forKey: Key.useFrecency)
        }
    }

    public var enabledProviders: Set<Provider> {
        get {
            let raw = defaults.stringArray(forKey: Key.providers) ?? []
            return Set(raw.compactMap(Provider.init(rawValue:)))
        }
        set {
            objectWillChange.send()
            defaults.set(newValue.map(\.rawValue).sorted(), forKey: Key.providers)
        }
    }

    public func isEnabled(_ provider: Provider) -> Bool {
        enabledProviders.contains(provider)
    }

    public func setEnabled(_ provider: Provider, _ enabled: Bool) {
        var providers = enabledProviders
        if enabled { providers.insert(provider) } else { providers.remove(provider) }
        enabledProviders = providers
    }
}

/// The launcher plugin: Spaceman's command palette. This file is the
/// registration and its settings; the panel lives in Launcher.swift.
///
/// The keybinding follows the Swift port's modifier convention (⌃⌥, matching
/// the core bindings) rather than the Go version's ⌘⌥ leader.
public enum LauncherPlugin: SpacemanPlugin {
    public static let name = "launcher"
    public static let displayName = "Launcher"
    public static let summary = "A command palette for apps, open windows, "
        + "window-manager actions and quick arithmetic."

    @MainActor
    public static func setup(host: any PluginHost) -> PluginInstance {
        let settings = LauncherSettings()

        // Usage history biases ranking so the app opened twenty times a day
        // stops sitting behind an alphabetically luckier one.
        let uses = Frecency(path: Frecency.defaultPath)

        // Providers are assembled from the enabled set rather than filtered
        // later: a disabled provider does no work at all.
        var providers: [any LauncherProvider] = []
        if settings.isEnabled(.calculator) { providers.append(CalcProvider()) }
        if settings.isEnabled(.apps) {
            providers.append(AppProvider(uses: settings.useFrecency ? uses : nil))
        }
        if settings.isEnabled(.windows) { providers.append(WindowProvider(host: host)) }
        if settings.isEnabled(.commands) { providers.append(CommandProvider(host: host)) }

        let launcher = Launcher(providers: providers,
                                palette: { [weak host] role in
                                    host?.color(role) ?? .labelColor
                                })
        launcher.onChoose = { uses.record($0) }
        launcher.resultLimit = { settings.maxResults }

        return PluginInstance(
            commands: [
                PluginCommand(
                    id: "launcher.toggle",
                    keyCode: UInt32(kVK_ANSI_O),
                    modifiers: UInt32(controlKey | optionKey),
                    group: .apps,
                    desc: "Launcher / command palette",
                    action: { launcher.toggle() }
                ),
            ],
            settings: PluginSettings {
                LauncherSettingsPane(settings: settings)
            }
        )
    }
}

private struct LauncherSettingsPane: View {
    @ObservedObject var settings: LauncherSettings

    var body: some View {
        Form {
            Section("Results") {
                ForEach(LauncherSettings.Provider.allCases, id: \.self) { provider in
                    Toggle(provider.title, isOn: Binding(
                        get: { settings.isEnabled(provider) },
                        set: { settings.setEnabled(provider, $0) }
                    ))
                }
            }

            Section {
                Stepper(value: Binding(
                    get: { settings.maxResults },
                    set: { settings.maxResults = $0 }
                ), in: 3...20) {
                    Text("Show at most \(settings.maxResults) results")
                }

                Toggle("Promote frequently used results", isOn: Binding(
                    get: { settings.useFrecency },
                    set: { settings.useFrecency = $0 }
                ))
                .help("Ranks by how often and how recently you pick something")
            }

            Section {
                Text("Result kinds take effect on the next launch — the "
                     + "launcher builds its providers once, so a disabled one "
                     + "does no work at all. The other settings apply "
                     + "immediately.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
