import Foundation
import PluginKit
import SpacemanCore

/// Per-command key overrides.
///
/// Only the *key* is configurable: the leader is a compile-time constant, so
/// every chord is leader+something and there is no modifier to record. Stored
/// one preference per command (`shortcut.<id>`), which keeps a plugin's binding
/// independent of load order and scriptable like everything else.
@MainActor
struct ShortcutBindings {

    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    private func key(for id: String) -> String { "shortcut.\(id)" }

    func override(for id: String) -> UInt32? {
        // Absent reads as 0, which is a real key code, so presence is checked
        // rather than the value.
        guard preferences.rawValue(forKey: key(for: id)) != nil else { return nil }
        let stored = preferences.integer(forKey: key(for: id))
        return stored >= 0 ? UInt32(stored) : nil
    }

    /// The key this command should register, override or built-in default.
    func keyCode(for command: PluginCommand) -> UInt32 {
        override(for: command.id) ?? command.keyCode
    }

    func hasOverrides(_ ids: [String]) -> Bool {
        ids.contains { override(for: $0) != nil }
    }

    /// Assign `text` — a single character — to the command.
    ///
    /// Refused when the character is not one we can turn into a key code, or
    /// when another command already holds it. A duplicate is worth refusing
    /// rather than warning about: the loser of a clash silently never fires.
    @discardableResult
    func assign(_ text: String, to command: PluginCommand) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard trimmed.count == 1, let code = ChordGlyphs.keyCode(for: trimmed) else {
            return false
        }
        guard !isTaken(code, modifiers: command.modifiers, excluding: command.id) else {
            return false
        }
        preferences.setInteger(Int(code), forKey: key(for: command.id))
        return true
    }

    func clear(_ id: String) {
        preferences.reset(key(for: id))
    }

    func resetAll(_ ids: [String]) {
        for id in ids { clear(id) }
    }

    /// Whether another command — after its own override — already uses `code`.
    func isTaken(_ code: UInt32, modifiers: UInt32, excluding id: String) -> Bool {
        assignedChords.contains {
            $0.key != id && $0.value.keyCode == code && $0.value.modifiers == modifiers
        }
    }

    /// Every key currently claimed by a plain leader chord, including app
    /// shortcuts edited this session. App shortcuts all use this modifier set,
    /// so commands using ⇧ or ⌘ do not unnecessarily consume their keys.
    var takenKeyCodes: Set<UInt32> {
        Set(assignedChords.values.compactMap {
            $0.modifiers == Modifiers.controlOption ? $0.keyCode : nil
        })
    }

    /// Command id → key code, for every command the app registered.
    ///
    /// Read from the live catalog rather than only from stored overrides, so a
    /// key held by a built-in default is still recognised as taken. App
    /// shortcuts are merged from preferences so a chord added in Settings is
    /// reserved immediately, not only after the next launch.
    private struct AssignedChord {
        let keyCode: UInt32
        let modifiers: UInt32
    }

    private var assignedChords: [String: AssignedChord] {
        var result: [String: AssignedChord] = [:]
        let liveAppIDs = Set(preferences.appShortcuts.map(\.commandID))
        for command in Self.registered {
            // A shortcut removed this session must free its key immediately.
            if command.id.hasPrefix("apps."), !liveAppIDs.contains(command.id) {
                continue
            }
            result[command.id] = AssignedChord(
                keyCode: override(for: command.id) ?? command.keyCode,
                modifiers: command.modifiers
            )
        }
        for shortcut in preferences.appShortcuts {
            result[shortcut.commandID] = AssignedChord(
                keyCode: shortcut.keyCode,
                modifiers: Modifiers.controlOption
            )
        }
        return result
    }

    /// The command table, published by the app at startup so this type can see
    /// it without owning it.
    nonisolated(unsafe) static var registered: [PluginCommand] = []
}

extension Preferences {
    var shortcuts: ShortcutBindings { ShortcutBindings(preferences: self) }
}

extension ChordGlyphs {
    /// The one direction the pane needs: a typed character to a key code.
    /// Deliberately limited to keys `RegisterEventHotKey` handles predictably.
    static func keyCode(for character: String) -> UInt32? {
        letters[character] ?? digits[character]
    }

    /// A key code back to what to show in the field.
    static func keyName(_ code: UInt32) -> String {
        if let match = letters.first(where: { $0.value == code }) { return match.key.uppercased() }
        if let match = digits.first(where: { $0.value == code }) { return match.key }
        return arrowsAndSpace[code] ?? "#\(code)"
    }

    private static let letters: [String: UInt32] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
        "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
        "m": 46,
    ]

    private static let digits: [String: UInt32] = [
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28,
        "9": 25, "0": 29, "-": 27, "=": 24,
    ]

    /// Not assignable in the pane — arrows and Space are structural — but they
    /// still need a name when shown.
    private static let arrowsAndSpace: [UInt32: String] = [
        49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]

    /// The leader, as glyphs. One constant, so the pane and the sheet agree.
    static var leaderGlyphs: String {
        string(keyCode: 0, modifiers: Modifiers.controlOption)
            .replacingOccurrences(of: keyName(0), with: "")
    }
}
