import Testing
@testable import SpacemanCore

@Suite("Display bar offsets")
struct DisplayBarOffsetsTests {

    @Test("corrupt JSON decodes as no offsets")
    func badJSONIsEmpty() {
        #expect(DisplayBarOffsetStore.decode("not json").isEmpty)
        #expect(DisplayBarOffsetStore.decode("").isEmpty)
    }

    @Test("offsets round-trip as readable JSON")
    func roundTrip() {
        let original = [
            "111": DisplayBarOffsets(top: 12, bottom: -8),
            "222": DisplayBarOffsets(top: 0, bottom: 24),
        ]
        let decoded = DisplayBarOffsetStore.decode(DisplayBarOffsetStore.encode(original))
        #expect(decoded == original)
    }
}
