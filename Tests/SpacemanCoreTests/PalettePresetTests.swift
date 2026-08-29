import Testing
import Foundation
@testable import SpacemanCore

@Suite("Palette presets")
struct PalettePresetTests {

    @Test("built-in names are unique")
    func namesAreUnique() {
        let names = PalettePreset.builtIns.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every built-in is flagged as one")
    func builtInsAreFlagged() {
        for palette in PalettePreset.builtIns {
            #expect(palette.isBuiltIn, "'\(palette.name)' is not flagged built-in")
        }
    }

    @Test("the default palette name resolves")
    func defaultNameResolves() {
        #expect(PalettePreset.builtIns.contains { $0.name == PalettePreset.defaultName })
    }

    @Test("System overrides nothing")
    func systemIsEmpty() {
        // The point of System: it is not a snapshot of the current macOS colours
        // but the absence of any override, so it keeps tracking the user's
        // accent, dark mode and contrast settings.
        #expect(PalettePreset.system.colors.isEmpty)
        for role in ThemeRole.allCases {
            #expect(PalettePreset.system.color(for: role) == nil)
        }
    }

    @Test("every other built-in covers every role")
    func opinionatedPalettesAreComplete() {
        // A partial palette resolves its gaps from the system, which mixes a
        // themed bar with system colours and looks accidental.
        for palette in PalettePreset.builtIns where palette.name != PalettePreset.system.name {
            for role in ThemeRole.allCases {
                #expect(palette.color(for: role) != nil,
                        "'\(palette.name)' has no colour for \(role.rawValue)")
            }
        }
    }

    @Test("built-in colour keys are all real roles")
    func colorKeysAreRoles() {
        // Keys are role raw values; a typo would silently mean "unset".
        let roles = Set(ThemeRole.allCases.map(\.rawValue))
        for palette in PalettePreset.builtIns {
            for key in palette.colors.keys {
                #expect(roles.contains(key), "'\(palette.name)' has unknown role '\(key)'")
            }
        }
    }

    @Test("a palette survives a JSON round trip")
    func roundTrips() throws {
        for palette in PalettePreset.builtIns {
            let data = try JSONEncoder().encode(palette)
            let decoded = try JSONDecoder().decode(PalettePreset.self, from: data)
            #expect(decoded == palette, "'\(palette.name)' did not survive")
        }
    }

    @Test("colours encode as hex strings")
    func colorsEncodeReadably() throws {
        // The stored palette is JSON in a preference, so it has to be legible
        // to whoever opens it.
        let palette = PalettePreset(name: "T", colors: ["accent": PaletteColor(HexColor("#FF8800"))])
        let json = String(data: try JSONEncoder().encode(palette), encoding: .utf8) ?? ""
        #expect(json.contains("#FF8800"))
    }

    @Test("setting one appearance leaves the other following the system")
    func setsOneAppearance() {
        var palette = PalettePreset(name: "T")
        palette.setColor(HexColor("#112233"), for: .accent, dark: false)

        #expect(palette.color(for: .accent)?.light == HexColor("#112233"))
        #expect(palette.color(for: .accent)?.dark == nil)
    }

    @Test("clearing both appearances removes the role entirely")
    func clearingRemovesTheEntry() {
        // Rather than leaving an empty entry, which would read as "overridden"
        // and keep the reset button enabled forever.
        var palette = PalettePreset(name: "T")
        palette.setColor(HexColor("#112233"), for: .accent, dark: false)
        palette.setColor(nil, for: .accent, dark: false)

        #expect(palette.colors["accent"] == nil)
        #expect(palette.color(for: .accent) == nil)
    }

    @Test("clear removes both appearances at once")
    func clearRemovesBoth() {
        var palette = PalettePreset.minimalDark
        palette.clear(.accent)
        #expect(palette.color(for: .accent) == nil)
    }

    @Test("duplicating clears the built-in flag and keeps the colours")
    func duplicating() {
        let copy = PalettePreset.minimalDark.duplicated(as: "Mine")
        #expect(!copy.isBuiltIn)
        #expect(copy.name == "Mine")
        #expect(copy.colors == PalettePreset.minimalDark.colors)
    }
}
