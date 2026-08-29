import Foundation
import SpacemanCore

/// Reads and writes a family of presets — bars, palettes — against two
/// preferences: the active preset's name, and the user's own presets as JSON.
///
/// Generic because bars and palettes differ only in what a preset *contains*.
/// The rules around them are identical, and they are the part worth getting
/// right once: built-ins are never stored, a name is unique across both sets,
/// deleting the active one falls back rather than breaking, and a corrupt
/// custom list degrades to "no custom presets" instead of taking the app down.
@MainActor
struct PresetStore<P: Preset> {

    private let preferences: Preferences
    private let activeKey: DefaultsKey<String>
    private let customKey: DefaultsKey<String>

    init(preferences: Preferences,
         activeKey: DefaultsKey<String>,
         customKey: DefaultsKey<String>) {
        self.preferences = preferences
        self.activeKey = activeKey
        self.customKey = customKey
    }

    /// Built-ins first, then the user's — the order Settings shows them in.
    var all: [P] { P.builtIns + custom }

    var custom: [P] {
        guard let data = preferences[customKey].data(using: .utf8) else { return [] }
        // A corrupt value means an empty custom list, not a crash: the built-ins
        // still work, so the app stays usable while the user fixes their JSON.
        return (try? JSONDecoder().decode([P].self, from: data)) ?? []
    }

    /// The preset in force. Falls back to the default when the stored name
    /// matches nothing — which is what a deletion or a typo'd script produces.
    var active: P {
        let name = preferences[activeKey]
        return all.first { $0.name == name }
            ?? P.builtIns.first { $0.name == P.defaultName }
            ?? P.builtIns[0]
    }

    var activeName: String {
        get { preferences[activeKey] }
        nonmutating set { preferences[activeKey] = newValue }
    }

    /// Insert or update a user preset and make it active. Built-ins are never
    /// written — an edit to one arrives here already duplicated.
    nonmutating func save(_ preset: P) {
        guard !preset.isBuiltIn else { return }
        var presets = custom
        if let index = presets.firstIndex(where: { $0.name == preset.name }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
        write(presets)
        activeName = preset.name
    }

    nonmutating func delete(_ name: String) {
        write(custom.filter { $0.name != name })
        if activeName == name { activeName = P.defaultName }
    }

    /// Rename a custom preset, keeping it active if it was.
    ///
    /// A blank or colliding name is refused rather than corrected, so the
    /// editor can leave the field showing what the user typed instead of
    /// silently substituting something else.
    @discardableResult
    nonmutating func rename(_ preset: P, to newName: String) -> Bool {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preset.isBuiltIn, !trimmed.isEmpty, trimmed != preset.name else { return false }
        guard !all.contains(where: { $0.name == trimmed }) else { return false }

        let wasActive = activeName == preset.name
        var presets = custom
        guard let index = presets.firstIndex(where: { $0.name == preset.name }) else { return false }
        presets[index].name = trimmed
        write(presets)
        if wasActive { activeName = trimmed }
        return true
    }

    /// A user-owned copy under a name nothing else is using.
    nonmutating func editableCopy(of preset: P) -> P {
        preset.duplicated(as: uniqueName(basedOn: preset.name))
    }

    /// "Powerline" → "Powerline Copy" → "Powerline Copy 2", the Finder pattern.
    func uniqueName(basedOn name: String) -> String {
        let taken = Set(all.map(\.name))
        guard taken.contains(name) else { return name }

        let base = name.hasSuffix(" Copy") ? name : name + " Copy"
        guard taken.contains(base) else { return base }

        var counter = 2
        while taken.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    private nonmutating func write(_ presets: [P]) {
        let encoder = JSONEncoder()
        // Readable, since the whole reason this is a JSON string is that someone
        // might open it.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(presets),
              let json = String(data: data, encoding: .utf8) else { return }
        preferences[customKey] = json
    }
}

extension Preferences {
    var barPresets: PresetStore<BarPreset> {
        PresetStore(preferences: self,
                    activeKey: Defaults.barPreset,
                    customKey: Defaults.barCustomPresets)
    }

    var palettes: PresetStore<PalettePreset> {
        PresetStore(preferences: self,
                    activeKey: Defaults.palette,
                    customKey: Defaults.customPalettes)
    }

    var activeBarPreset: BarPreset { barPresets.active }
    var activePalette: PalettePreset { palettes.active }
}
