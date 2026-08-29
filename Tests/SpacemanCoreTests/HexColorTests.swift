import Testing
@testable import SpacemanCore

@Suite("HexColor")
struct HexColorTests {

    @Test("parses six-digit hex")
    func sixDigit() {
        let color = HexColor("#FF8800")
        #expect(color?.red == 1)
        #expect(color?.green == Double(0x88) / 255)
        #expect(color?.blue == 0)
        #expect(color?.alpha == 1)
    }

    @Test("the leading hash is optional")
    func hashOptional() {
        // A colour picker writes one, a shell heredoc often doesn't.
        #expect(HexColor("FF8800") == HexColor("#FF8800"))
    }

    @Test("case does not matter")
    func caseInsensitive() {
        #expect(HexColor("#ff8800") == HexColor("#FF8800"))
    }

    @Test("short form repeats each digit, as CSS does")
    func shortForm() {
        #expect(HexColor("#f80") == HexColor("#FF8800"))
        #expect(HexColor("#f80c") == HexColor("#FF8800CC"))
    }

    @Test("eight digits carry alpha")
    func withAlpha() {
        let color = HexColor("#00000080")
        #expect(color?.alpha == Double(0x80) / 255)
    }

    @Test("nonsense is rejected rather than read as black")
    func rejectsGarbage() {
        // The point of returning nil: an unparseable override falls back to the
        // system colour. Reading these as black would paint the bar a colour
        // nobody chose and look like a rendering bug.
        #expect(HexColor("") == nil)
        #expect(HexColor("#") == nil)
        #expect(HexColor("blue") == nil)
        #expect(HexColor("#GG0000") == nil)
        #expect(HexColor("#FF880") == nil, "5 digits is not a hex colour")
        #expect(HexColor("#FF88000") == nil, "7 digits is not a hex colour")
    }

    @Test("surrounding whitespace is tolerated")
    func trimsWhitespace() {
        #expect(HexColor("  #FF8800\n") == HexColor("#FF8800"))
    }

    @Test("opaque colours round-trip through the short form")
    func roundTripsOpaque() {
        // What a user pastes in is what they get back out of `defaults read`.
        #expect(HexColor("#FF8800")?.hexString == "#FF8800")
    }

    @Test("translucent colours keep their alpha pair")
    func roundTripsAlpha() {
        #expect(HexColor("#FF880080")?.hexString == "#FF880080")
    }

    @Test("every parseable colour survives a round trip")
    func roundTripIsLossless() {
        for value in stride(from: 0, through: 255, by: 17) {
            let hex = String(format: "#%02X%02X%02X", value, 255 - value, value)
            #expect(HexColor(hex)?.hexString == hex)
        }
    }

    @Test("out-of-range components are clamped, not rejected")
    func clampsComponents() {
        // These come from float maths in a colour picker, not user intent.
        let color = HexColor(red: 1.4, green: -0.2, blue: 0.5, alpha: 9)
        #expect(color.red == 1)
        #expect(color.green == 0)
        #expect(color.alpha == 1)
        #expect(color.hexString == "#FF0080")
    }
}
