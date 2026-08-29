import AppKit
import SwiftUI
import SpacemanCore

/// Resolves semantic colour roles to actual colours.
///
/// Each role has a system colour behind it, so an untouched install tracks the
/// user's accent from System Settings, flips with dark mode, and responds to
/// Increase Contrast — none of which a file of hex values can do. A role the
/// user overrides in Settings wins over that, per appearance.
///
/// The Go original's `theme.toml` was 15 literal colours with no light/dark
/// concept at all; this keeps the full palette editing it offered while making
/// "I never opened Settings" the case that looks best.
@MainActor
enum Theme {

    /// The colour for `role`, honouring any override.
    ///
    /// When a role is overridden the result is a *dynamic* `NSColor`: it holds
    /// both appearances and resolves at draw time, so a window dragged between a
    /// light and dark context repaints correctly without anything being
    /// re-created. Overrides are read once, here, rather than captured by
    /// reference — the provider must not reach back into the preference store
    /// from whatever thread AppKit calls it on.
    static func color(_ role: ThemeRole, from preferences: Preferences) -> Color {
        color(role, in: preferences.activePalette)
    }

    /// The `NSColor` behind `color(_:in:)`, for AppKit call sites — plugin
    /// panels are built with AppKit views, so they need the colour itself rather
    /// than a SwiftUI wrapper.
    static func nsColor(_ role: ThemeRole, in palette: PalettePreset) -> NSColor {
        guard let entry = palette.color(for: role) else { return role.systemColor }
        return NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            guard let hex = entry[dark: isDark] else { return role.systemColor }
            return NSColor(hex)
        }
    }

    /// As above, but against a named palette — the Settings editor previews a
    /// palette that is not necessarily the active one.
    static func color(_ role: ThemeRole, in palette: PalettePreset) -> Color {
        guard let entry = palette.color(for: role) else {
            return Color(nsColor: role.systemColor)
        }

        return Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            // Falling through to the system colour when only one appearance is
            // set keeps a half-configured palette coherent instead of forcing
            // the user to fill in both.
            guard let hex = entry[dark: isDark] else { return role.systemColor }
            return NSColor(hex)
        })
    }

    /// A section's colour, which may name a role or a literal.
    ///
    /// Roles keep adapting — a section filled with `.role(.accent)` follows the
    /// user's system accent and their dark mode. A hex is frozen by definition,
    /// which is exactly why a powerline preset uses one.
    static func color(_ reference: ColorRef, from preferences: Preferences) -> Color {
        switch reference {
        case .role(let role): return color(role, from: preferences)
        case .hex(let hex):   return Color(nsColor: NSColor(hex))
        }
    }

    static func color(_ reference: ColorRef, in palette: PalettePreset) -> Color {
        switch reference {
        case .role(let role): return color(role, in: palette)
        case .hex(let hex):   return Color(nsColor: NSColor(hex))
        }
    }

    /// What `role` resolves to right now under `appearance`, override or not.
    /// The Settings colour wells show this, so an unedited well displays the
    /// colour actually in use rather than an empty swatch.
    static func resolved(_ role: ThemeRole, dark: Bool,
                         in palette: PalettePreset) -> HexColor {
        if let override = palette.color(for: role)?[dark: dark] { return override }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            ?? NSAppearance.currentDrawing()
        var resolved = HexColor(red: 0, green: 0, blue: 0)
        appearance.performAsCurrentDrawingAppearance {
            resolved = role.systemColor.hexColor
        }
        return resolved
    }
}

extension ThemeRole {
    /// The system colour this role derives from when the user hasn't overridden
    /// it. Every one of these is dynamic — it already carries its own light,
    /// dark and increased-contrast variants.
    var systemColor: NSColor {
        switch self {
        case .background: return .windowBackgroundColor
        case .surface:    return .controlBackgroundColor
        case .text:       return .labelColor
        case .muted:      return .secondaryLabelColor
        case .accent:     return .controlAccentColor
        case .good:       return .systemGreen
        case .warn:       return .systemOrange
        case .danger:     return .systemRed
        case .separator:  return .separatorColor
        // The bar tints are the values the bars were previously hardcoding, kept
        // as label-derived alphas so they stay legible against any material.
        case .barSurface: return .labelColor.withAlphaComponent(0.04)
        case .barSegment: return .labelColor.withAlphaComponent(0.07)
        }
    }
}

extension NSColor {
    convenience init(_ hex: HexColor) {
        self.init(srgbRed: hex.red, green: hex.green, blue: hex.blue, alpha: hex.alpha)
    }

    /// Converted to sRGB first: system colours live in catalog colour spaces
    /// where the component accessors trap.
    var hexColor: HexColor {
        guard let srgb = usingColorSpace(.sRGB) else { return HexColor(red: 0, green: 0, blue: 0) }
        return HexColor(red: srgb.redComponent, green: srgb.greenComponent,
                        blue: srgb.blueComponent, alpha: srgb.alphaComponent)
    }
}

extension Color {
    /// SwiftUI `Color` → `HexColor`, for reading a `ColorPicker` back out.
    var hexColor: HexColor { NSColor(self).hexColor }
}
