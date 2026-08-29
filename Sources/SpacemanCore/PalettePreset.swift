import Foundation

/// One role's colour, per appearance. A nil side derives from the system.
///
/// Both sides being nil is meaningful and common: it means "this role is
/// whatever macOS says", which is why `System` can be an empty palette rather
/// than a copy of the current system colours frozen at build time.
public struct PaletteColor: Codable, Equatable, Sendable {
    public var light: HexColor?
    public var dark: HexColor?

    public init(light: HexColor? = nil, dark: HexColor? = nil) {
        self.light = light
        self.dark = dark
    }

    /// Both appearances the same, for palettes that don't distinguish.
    public init(_ both: HexColor?) {
        self.light = both
        self.dark = both
    }

    public var isEmpty: Bool { light == nil && dark == nil }

    public subscript(dark isDark: Bool) -> HexColor? {
        get { isDark ? dark : light }
        set { if isDark { dark = newValue } else { light = newValue } }
    }
}

/// A named set of colour-role overrides.
///
/// Absence is the important case: a role with no entry resolves from macOS's
/// semantic colour for it, so it keeps tracking the user's accent, dark mode and
/// Increase Contrast. A palette only overrides what it has an opinion about.
public struct PalettePreset: Preset {
    public var name: String
    public var isBuiltIn: Bool
    /// Keyed by `ThemeRole.rawValue`, so the stored JSON reads as
    /// `"accent": {"light": "#5E5CE6"}`.
    public var colors: [String: PaletteColor]

    public init(name: String, colors: [String: PaletteColor] = [:], isBuiltIn: Bool = false) {
        self.name = name
        self.colors = colors
        self.isBuiltIn = isBuiltIn
    }

    public func color(for role: ThemeRole) -> PaletteColor? {
        colors[role.rawValue].flatMap { $0.isEmpty ? nil : $0 }
    }

    public mutating func setColor(_ color: HexColor?, for role: ThemeRole, dark: Bool) {
        var entry = colors[role.rawValue] ?? PaletteColor()
        entry[dark: dark] = color
        if entry.isEmpty {
            colors.removeValue(forKey: role.rawValue)
        } else {
            colors[role.rawValue] = entry
        }
    }

    public mutating func clear(_ role: ThemeRole) {
        colors.removeValue(forKey: role.rawValue)
    }

    public func duplicated(as newName: String) -> PalettePreset {
        PalettePreset(name: newName, colors: colors, isBuiltIn: false)
    }
}

// MARK: - Built-in palettes

public extension PalettePreset {

    static let builtIns: [PalettePreset] = [.system, .minimalDark, .midnight, .paper]

    static var defaultName: String { system.name }

    /// No overrides at all: every role resolves from macOS. Accent follows
    /// System Settings, everything flips with dark mode, and Increase Contrast
    /// is honoured — none of which a palette of fixed values can do.
    static let system = PalettePreset(name: "System", isBuiltIn: true)

    /// The Go version's theme, carried over from its `defaultTOML`
    /// (`internal/ui/theme/theme.go`): macOS system greys with Apple's system
    /// colours over them.
    ///
    /// Both appearances get the same values because the original had only one —
    /// it was written against macOS dark mode and had no concept of a light
    /// variant. Splitting it would mean inventing half a theme, so Spaceman is
    /// simply a dark palette in either appearance, as it always was.
    ///
    /// Go's `bar_tint`, `bar_highlight` and `bar_border` map onto the port's
    /// `barSurface`, `barSegment` and `separator`. Its `accent_alt`,
    /// `surface_hover`, `selection`, `bar_tint_to` and `bar_stat` have no role
    /// here yet — the port has no consumer for them.
    static let minimalDark = PalettePreset(
        name: "Minimal Dark",
        colors: [
            "background": PaletteColor(hex("#1E1E1E")),   // bg
            "surface":    PaletteColor(hex("#2D2D2F")),   // surface
            // Lifted from Go's #F5F5F7: over a frosted bar the blur lets the
            // desktop through and eats the contrast of small text.
            "text":       PaletteColor(hex("#FFFFFF")),
            "muted":      PaletteColor(hex("#9A9AA0")),   // lifted from #7C7C82
            "accent":     PaletteColor(hex("#0A84FF")),   // accent
            "good":       PaletteColor(hex("#30D158")),   // good
            "warn":       PaletteColor(hex("#FF9F0A")),   // warn
            "danger":     PaletteColor(hex("#FF453A")),   // danger
            "separator":  PaletteColor(hex("#FFFFFF1F")), // bar_border
            "barSurface": PaletteColor(hex("#141416CC")), // bar_tint
            "barSegment": PaletteColor(hex("#FFFFFF14")), // bar_highlight
        ],
        isBuiltIn: true
    )

    /// Dark in both appearances, for bars that should read as chrome whatever
    /// the rest of the desktop is doing.
    static let midnight = PalettePreset(
        name: "Midnight",
        colors: [
            "accent":     PaletteColor(hex("#4CC2FF")),
            "background": PaletteColor(hex("#0B0F17")),
            "surface":    PaletteColor(hex("#161C28")),
            "text":       PaletteColor(hex("#E6EDF7")),
            "muted":      PaletteColor(hex("#7C8899")),
            "good":       PaletteColor(hex("#3FB950")),
            "warn":       PaletteColor(hex("#D29922")),
            "danger":     PaletteColor(hex("#F85149")),
            "separator":  PaletteColor(hex("#FFFFFF1F")),
            "barSurface": PaletteColor(hex("#FFFFFF0A")),
            "barSegment": PaletteColor(hex("#FFFFFF16")),
        ],
        isBuiltIn: true
    )

    /// Warm and light in both appearances.
    static let paper = PalettePreset(
        name: "Paper",
        colors: [
            "accent":     PaletteColor(hex("#B25A2E")),
            "background": PaletteColor(hex("#FBF6EC")),
            "surface":    PaletteColor(hex("#F0E8D8")),
            "text":       PaletteColor(hex("#3A332A")),
            "muted":      PaletteColor(hex("#8A7F6D")),
            "good":       PaletteColor(hex("#5B7A3C")),
            "warn":       PaletteColor(hex("#B8860B")),
            "danger":     PaletteColor(hex("#A33A28")),
            "separator":  PaletteColor(hex("#3A332A26")),
            "barSurface": PaletteColor(hex("#3A332A0A")),
            "barSegment": PaletteColor(hex("#3A332A16")),
        ],
        isBuiltIn: true
    )

    /// Built-in palettes are written as literals, so a typo would silently mean
    /// "derive from the system" for that role. Force-unwrapping turns that into
    /// a crash on the first launch of a broken build instead — and the test
    /// suite checks every built-in parses.
    private static func hex(_ value: String) -> HexColor {
        guard let color = HexColor(value) else {
            preconditionFailure("built-in palette has an invalid colour: \(value)")
        }
        return color
    }
}
