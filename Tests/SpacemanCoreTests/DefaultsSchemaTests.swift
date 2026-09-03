import Testing
import Foundation
@testable import SpacemanCore

@Suite("Defaults schema")
struct DefaultsSchemaTests {

    /// Every key declared in `Defaults`, so the tests below can be exhaustive
    /// rather than a sample. Adding a key without adding it here fails
    /// `registrationCoversEveryKey`.
    private let doubleKeys: [DefaultsKey<Double>] = [
        Defaults.gap, Defaults.outerGap, Defaults.masterRatio,
        Defaults.zoomFraction, Defaults.animationDuration, Defaults.hoverSeconds,
    ]
    private let stringKeys: [DefaultsKey<String>] = [
        Defaults.defaultLayout,
        Defaults.barPreset, Defaults.barCustomPresets, Defaults.barDisplayOffsets,
        Defaults.palette, Defaults.customPalettes,
        Defaults.appShortcuts,
    ]
    private let boolKeys: [DefaultsKey<Bool>] = [
        Defaults.animationEnabled, Defaults.followMouse, Defaults.barEdgeReveal,
    ]

    @Test("every declared key has a registered default")
    func registrationCoversEveryKey() {
        // The registration domain is what makes an unset key safe to read, so a
        // key missing from it would resolve to zero rather than its fallback —
        // a gap of 0 or a bar 0pt tall, silently.
        let registration = Defaults.registration
        let names = doubleKeys.map(\.name) + stringKeys.map(\.name) + boolKeys.map(\.name)

        for name in names {
            #expect(registration[name] != nil, "'\(name)' has no registered default")
        }
        #expect(registration.count == names.count, "registration has entries no key declares")
    }

    @Test("key names are unique")
    func namesAreUnique() {
        let names = doubleKeys.map(\.name) + stringKeys.map(\.name) + boolKeys.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("key names are dotted section.setting pairs")
    func namesAreSectioned() {
        // `defaults read com.spaceman.app` groups readably, and the
        // sections stay recognisable as the Go config's TOML tables.
        let names = doubleKeys.map(\.name) + stringKeys.map(\.name) + boolKeys.map(\.name)
        for name in names {
            #expect(name.split(separator: ".").count == 2, "'\(name)' is not section.setting")
        }
    }

    @Test("registered defaults are plist types")
    func registrationIsPlistSafe() {
        // UserDefaults silently refuses anything else, which would leave the key
        // unregistered and reading as zero.
        for value in Defaults.registration.values {
            #expect(value is Double || value is String || value is Bool,
                    "\(type(of: value)) is not a property-list type")
        }
    }

    @Test("no default is outside its own clamp range")
    func defaultsSurviveTheirOwnClamp() {
        // A fallback the app would immediately clamp is a fallback nobody can
        // actually get back to by resetting.
        for key in doubleKeys {
            #expect(Defaults.clamp(key.fallback, for: key) == key.fallback,
                    "'\(key.name)' default \(key.fallback) is outside its clamp range")
        }
    }

    @Test("clamping pulls absurd values back into range")
    func clampBounds() {
        // `defaults write` accepts anything; this is the guard against a typo'd
        // gap leaving no room for a window.
        #expect(Defaults.clamp(-5, for: Defaults.gap) == 0)
        #expect(Defaults.clamp(9999, for: Defaults.gap) == 200)
        #expect(Defaults.clamp(0, for: Defaults.masterRatio) == 0.1)
        #expect(Defaults.clamp(1, for: Defaults.masterRatio) == 0.9)
        #expect(Defaults.clamp(3, for: Defaults.animationDuration) == 2)
    }

    @Test("the default layout string is a layout the app knows")
    func defaultLayoutParses() {
        // The setting is stored as text so `defaults write … master` works, which
        // means the fallback itself has to survive the same parse.
        #expect(LayoutMode(userInput: Defaults.defaultLayout.fallback) != nil)
    }

    @Test("the active preset names resolve to built-ins")
    func activePresetDefaultsResolve() {
        // The fallback has to name something that exists, or a fresh install
        // would start on a preset the store cannot find.
        #expect(BarPreset.builtIns.contains { $0.name == Defaults.barPreset.fallback })
        #expect(PalettePreset.builtIns.contains { $0.name == Defaults.palette.fallback })
    }

    @Test("the custom preset defaults are empty JSON arrays")
    func customPresetDefaultsAreValid() {
        // They are decoded on every read, so an unparseable fallback would make
        // a fresh install look like it had corrupt presets.
        for key in [Defaults.barCustomPresets, Defaults.customPalettes, Defaults.appShortcuts] {
            let data = Data(key.fallback.utf8)
            #expect((try? JSONSerialization.jsonObject(with: data)) as? [Any] != nil,
                    "'\(key.name)' default is not a JSON array")
        }
    }

    @Test("display bar offsets default to an empty JSON object")
    func displayOffsetsDefaultIsValid() {
        let data = Data(Defaults.barDisplayOffsets.fallback.utf8)
        #expect((try? JSONSerialization.jsonObject(with: data)) as? [String: Any] != nil,
                "'\(Defaults.barDisplayOffsets.name)' default is not a JSON object")
    }

    @Test("individual theme roles are not registered")
    func themeRolesHaveNoFallback() {
        // Colours live inside a palette preset, not as one key per role. A
        // registered role would resolve as "overridden" for every palette and
        // freeze that colour everywhere.
        let roleKeys = ThemeRole.allCases.map { "theme.\($0.rawValue)" }
        for key in Defaults.registration.keys {
            #expect(!roleKeys.contains(key))
        }
    }
}
