import Foundation

/// The preference schema: every key the app reads, with the value it falls back
/// to when nobody has set it.
///
/// Preferences live in `UserDefaults`, not a config file. That is not merely a
/// different file format — a read walks an ordered list of domains and returns
/// the first hit:
///
///     argument      ./Spaceman -tiling.gap 20        (per launch, free)
///     managed       MDM configuration profile        (overrides the user)
///     application   ~/Library/Preferences/….plist    (defaults write, Settings)
///     registration  the fallbacks declared here      (never written to disk)
///
/// The registration domain is why there is no parser, no validation pass and no
/// default file written on first run: an unset key resolves to the value below,
/// and a key set to the wrong type resolves there too. There is no malformed
/// state to report, so the Go version's tolerant TOML reader and `-check-config`
/// have no counterpart here.
///
/// Keys are declared in this target — which has no AppKit — so that "every
/// setting has a registered default" is a test rather than a convention.

/// A preference key and its fallback, tied together so neither can be declared
/// without the other.
public struct DefaultsKey<Value: Sendable>: Sendable {
    /// The `defaults write` name, e.g. `tiling.gap`. Dotted sections mirror the
    /// Go config's TOML tables so the two are recognisably the same settings.
    public let name: String
    public let fallback: Value

    public init(_ name: String, _ fallback: Value) {
        self.name = name
        self.fallback = fallback
    }
}

public enum Defaults {

    // MARK: - Tiling

    public static let gap = DefaultsKey<Double>("tiling.gap", 12)
    public static let outerGap = DefaultsKey<Double>("tiling.outerGap", 12)
    public static let masterRatio = DefaultsKey<Double>("tiling.masterRatio", 0.6)
    /// Fraction of the tiling area a zoomed window covers.
    public static let zoomFraction = DefaultsKey<Double>("tiling.zoomFraction", 0.8)
    /// Layout a Space starts in, as a `LayoutMode(userInput:)` spelling.
    public static let defaultLayout = DefaultsKey<String>("tiling.defaultLayout", "spaceman")

    // MARK: - Focus

    /// Focus-follows-mouse. Off by default: it changes what typing does, so it
    /// has to be asked for.
    public static let followMouse = DefaultsKey<Bool>("focus.followMouse", false)
    /// How long the pointer must rest on a window before focus moves, so
    /// crossing one on the way somewhere else does not steal focus.
    public static let hoverSeconds = DefaultsKey<Double>("focus.hoverSeconds", 0.2)

    // MARK: - Animation

    public static let animationEnabled = DefaultsKey<Bool>("animation.enabled", true)
    public static let animationDuration = DefaultsKey<Double>("animation.duration", 0.14)

    // MARK: - Bars

    /// The active preset's name — built-in or user-created.
    public static let barPreset = DefaultsKey<String>("bar.preset", BarPreset.defaultName)
    /// User-created presets, as a JSON array.
    ///
    /// A JSON *string* rather than archived data or a nested plist, for the same
    /// reason colours are hex: it stays readable in `defaults read` and editable
    /// from a script. Height, material and everything else about a bar lives
    /// inside the preset, which is why there are no separate keys for them.
    public static let barCustomPresets = DefaultsKey<String>("bar.customPresets", "[]")
    /// Per-display vertical bar offsets, keyed by CoreGraphics display ID.
    public static let barDisplayOffsets = DefaultsKey<String>("bar.displayOffsets", "{}")
    /// Slide a bar out of the way when the pointer hits that screen edge.
    public static let barEdgeReveal = DefaultsKey<Bool>("bar.edgeReveal", true)

    // MARK: - Palette

    /// The active colour palette's name — built-in or user-created.
    public static let palette = DefaultsKey<String>("theme.palette", PalettePreset.defaultName)
    /// User-created palettes, as a JSON array.
    public static let customPalettes = DefaultsKey<String>("theme.customPalettes", "[]")

    // MARK: - App shortcuts

    /// User-defined "open this app" chords, as a JSON array of `AppShortcut`.
    public static let appShortcuts = DefaultsKey<String>("apps.shortcuts", "[]")

    /// Everything above, as `UserDefaults.register(defaults:)` wants it.
    ///
    /// Computed rather than stored: a stored `[String: Any]` is a non-Sendable
    /// global, which this target's Swift 6 mode correctly rejects.
    ///
    /// Theme overrides are deliberately absent. They have no fallback — an
    /// unset role means "derive from the system colour", which is a different
    /// thing from "fall back to this value", and registering one would make
    /// every role look permanently overridden.
    public static var registration: [String: Any] {
        [
            gap.name: gap.fallback,
            outerGap.name: outerGap.fallback,
            masterRatio.name: masterRatio.fallback,
            zoomFraction.name: zoomFraction.fallback,
            defaultLayout.name: defaultLayout.fallback,
            followMouse.name: followMouse.fallback,
            hoverSeconds.name: hoverSeconds.fallback,
            animationEnabled.name: animationEnabled.fallback,
            animationDuration.name: animationDuration.fallback,
            barPreset.name: barPreset.fallback,
            barCustomPresets.name: barCustomPresets.fallback,
            barDisplayOffsets.name: barDisplayOffsets.fallback,
            barEdgeReveal.name: barEdgeReveal.fallback,
            palette.name: palette.fallback,
            customPalettes.name: customPalettes.fallback,
            appShortcuts.name: appShortcuts.fallback,
        ]
    }

    /// Sane bounds for the numeric settings, applied on read.
    ///
    /// `defaults write` accepts anything, so these are the app's guard against a
    /// typo'd `tiling.gap 1200` leaving no room for a window. Clamping rather
    /// than rejecting keeps the "no error state" property of the registration
    /// domain: an absurd value degrades to the nearest sane one.
    public static func clamp(_ value: Double, for key: DefaultsKey<Double>) -> Double {
        switch key.name {
        case gap.name, outerGap.name:   return min(max(value, 0), 200)
        case masterRatio.name:          return min(max(value, 0.1), 0.9)
        case zoomFraction.name:         return min(max(value, 0.2), 1.0)
        case animationDuration.name:    return min(max(value, 0), 2)
        case hoverSeconds.name:         return min(max(value, 0), 3)
        default:                        return value
        }
    }
}

/// A semantic colour role.
///
/// Roles, not literal colours, so a palette can resolve from system colours by
/// default — accent tracks System Settings, everything adapts to dark mode and
/// increased contrast — while still being fully overridable per role and per
/// appearance. Which overrides apply is decided by the active `PalettePreset`.
public enum ThemeRole: String, CaseIterable, Sendable {
    case background, surface, text, muted, accent
    case good, warn, danger, separator
    case barSurface, barSegment

    public var title: String {
        switch self {
        case .background: return "Background"
        case .surface:    return "Surface"
        case .text:       return "Text"
        case .muted:      return "Muted text"
        case .accent:     return "Accent"
        case .good:       return "Good"
        case .warn:       return "Warning"
        case .danger:     return "Danger"
        case .separator:  return "Separator"
        case .barSurface: return "Bar tint"
        case .barSegment: return "Bar segment"
        }
    }

}
