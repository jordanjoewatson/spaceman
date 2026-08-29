import Foundation

/// What a user-defined app chord does.
public enum AppShortcutKind: String, Codable, Sendable, CaseIterable {
    /// Launch the app, or bring it forward. Windows tile as usual.
    case open
    /// Toggle an untiled floating window: show it, or minimize it.
    case popup

    public var title: String {
        switch self {
        case .open:  return "Open"
        case .popup: return "Popup"
        }
    }

    public var helpVerb: String {
        switch self {
        case .open:  return "Open"
        case .popup: return "Toggle"
        }
    }
}

/// A user-defined chord that opens an application, or toggles it as a popup.
///
/// Stored as JSON in `apps.shortcuts` so a `defaults read` stays readable and
/// a script can add or remove entries the same way it edits bar presets.
public struct AppShortcut: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    /// Filesystem path of the `.app` bundle at the time it was added.
    public var path: String
    /// Preferred lookup when the app has moved; optional because a dropped
    /// folder of binaries may not have one.
    public var bundleIdentifier: String?
    /// Carbon key code. The leader is always ⌃⌥; only the key varies.
    public var keyCode: UInt32
    public var kind: AppShortcutKind

    public init(id: String = UUID().uuidString,
                name: String,
                path: String,
                bundleIdentifier: String? = nil,
                keyCode: UInt32,
                kind: AppShortcutKind = .open) {
        self.id = id
        self.name = name
        self.path = path
        self.bundleIdentifier = bundleIdentifier
        self.keyCode = keyCode
        self.kind = kind
    }

    /// Missing `kind` is `open`, so shortcuts saved before popups still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        path = try container.decode(String.self, forKey: .path)
        bundleIdentifier = try container.decodeIfPresent(String.self, forKey: .bundleIdentifier)
        keyCode = try container.decode(UInt32.self, forKey: .keyCode)
        kind = try container.decodeIfPresent(AppShortcutKind.self, forKey: .kind) ?? .open
    }

    /// Command id, namespaced by kind so an open chord and a popup chord for
    /// the same app can coexist.
    public var commandID: String { "apps.\(kind.rawValue).\(id)" }

    public static func decodeList(_ json: String) -> [AppShortcut] {
        guard let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([AppShortcut].self, from: data)
        else { return [] }
        return items
    }

    public static func encodeList(_ items: [AppShortcut]) -> String {
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8)
        else { return "[]" }
        return json
    }

    /// Letters that are unused by the built-in chords, T first — it used to
    /// open the in-app tracker, and is the natural key for a standalone one.
    public static let preferredKeyCodes: [UInt32] = [
        17, // T
        0,  // A
        11, // B
        14, // E
        5,  // G
        34, // I
        38, // J
        40, // K
        37, // L
        45, // N
        12, // Q
        32, // U
        9,  // V
        13, // W
        7,  // X
        16, // Y
        6,  // Z
    ]

    public static func firstFreeKey(taken: Set<UInt32>) -> UInt32? {
        preferredKeyCodes.first { !taken.contains($0) }
    }
}
