import Foundation

/// Per-display vertical nudges for the two bars.
///
/// Bar presets are global, but monitor geometry is not: a laptop panel may
/// need the top bar pulled down under a camera housing while an external screen
/// wants the bottom bar pushed up above a bezel or dock. These offsets therefore
/// live outside the preset system as one JSON object keyed by display ID.
public struct DisplayBarOffsets: Codable, Equatable, Sendable {
    public var top: Double
    public var bottom: Double

    public init(top: Double = 0, bottom: Double = 0) {
        self.top = top
        self.bottom = bottom
    }
}

public enum DisplayBarOffsetStore {
    public static func decode(_ json: String) -> [String: DisplayBarOffsets] {
        guard let data = json.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: DisplayBarOffsets].self, from: data)) ?? [:]
    }

    public static func encode(_ offsets: [String: DisplayBarOffsets]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(offsets),
              let json = String(data: data, encoding: .utf8) else { return "{}" }
        return json
    }
}
