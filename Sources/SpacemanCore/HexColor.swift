import Foundation

/// An sRGB colour parsed from a hex string.
///
/// Colours are stored in preferences as text rather than archived `NSColor`
/// data. The orthodox AppKit encoding is `NSKeyedArchiver`, but that produces an
/// opaque blob, and this app's configuration story is shell scripts:
///
///     defaults write com.spaceman.app theme.accent "#FF6600"
///
/// has to work. Text is also the only encoding a person can read back out of
/// `defaults read` and recognise.
///
/// Parsing is deliberately tolerant about *shape* (`#RGB`, `#RRGGBB`, with or
/// without the hash) and strict about *content* — a string that isn't a colour
/// returns nil rather than a silent black, so a typo falls back to the system
/// colour instead of painting the bar a colour nobody chose.
public struct HexColor: Equatable, Sendable, Codable {

    /// Components in 0...1, sRGB.
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red.clampedToUnit
        self.green = green.clampedToUnit
        self.blue = blue.clampedToUnit
        self.alpha = alpha.clampedToUnit
    }

    /// Parse `#RGB`, `#RGBA`, `#RRGGBB` or `#RRGGBBAA`. The leading `#` is
    /// optional because a shell heredoc and a colour picker disagree about
    /// whether it belongs.
    public init?(_ text: String) {
        var digits = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return nil }

        // Short forms repeat each digit: #f80 is #ff8800, matching CSS.
        let expanded: String
        switch digits.count {
        case 3, 4: expanded = digits.map { "\($0)\($0)" }.joined()
        case 6, 8: expanded = digits
        default:   return nil
        }

        func component(at index: Int) -> Double {
            let start = expanded.index(expanded.startIndex, offsetBy: index * 2)
            let end = expanded.index(start, offsetBy: 2)
            // Already validated as hex digits, so this cannot fail.
            return Double(UInt8(expanded[start..<end], radix: 16) ?? 0) / 255
        }

        self.red = component(at: 0)
        self.green = component(at: 1)
        self.blue = component(at: 2)
        self.alpha = expanded.count == 8 ? component(at: 3) : 1
    }

    /// `#RRGGBB`, or `#RRGGBBAA` when the colour is translucent.
    ///
    /// Opaque colours drop the alpha pair so the common case stays the short
    /// familiar form — what a user pastes in is what they get back out.
    public var hexString: String {
        func byte(_ value: Double) -> String {
            String(format: "%02X", Int((value * 255).rounded()))
        }
        let rgb = byte(red) + byte(green) + byte(blue)
        return alpha >= 1 ? "#\(rgb)" : "#\(rgb)\(byte(alpha))"
    }
}

public extension HexColor {
    /// Encoded as the hex string itself, so a stored palette reads as
    /// `"accent": {"light": "#FF8800"}` rather than four floating-point
    /// components nobody can recognise.
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = HexColor(text) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "'\(text)' is not a hex colour"))
        }
        self = parsed
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hexString)
    }
}

private extension Double {
    /// Out-of-range components come from float maths in a colour picker, not
    /// from user intent — clamping is the accurate reading, not a rejection.
    var clampedToUnit: Double { Swift.min(Swift.max(self, 0), 1) }
}
