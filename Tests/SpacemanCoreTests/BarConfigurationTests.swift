import Testing
import Foundation
@testable import SpacemanCore

@Suite("Bar configuration")
struct BarConfigurationTests {

    // MARK: - Round tripping

    @Test("a preset survives a JSON round trip")
    func presetRoundTrips() throws {
        // Presets are stored as JSON in a preference, so this is the storage
        // format, not just a serialisation detail.
        for preset in BarPreset.builtIns {
            let data = try JSONEncoder().encode(preset)
            let decoded = try JSONDecoder().decode(BarPreset.self, from: data)
            #expect(decoded == preset, "'\(preset.name)' did not survive")
        }
    }

    @Test("a colour role encodes as its bare name")
    func roleEncodesAsString() throws {
        let data = try JSONEncoder().encode(ColorRef.role(.accent))
        #expect(String(data: data, encoding: .utf8) == "\"accent\"")
    }

    @Test("a literal colour encodes as hex")
    func hexEncodesAsString() throws {
        let color = HexColor("#FF8800")!
        let data = try JSONEncoder().encode(ColorRef.hex(color))
        #expect(String(data: data, encoding: .utf8) == "\"#FF8800\"")
    }

    @Test("both colour spellings decode")
    func colorRefDecodes() throws {
        // The same grammar the Go config accepted, so a section definition can
        // be copied across unchanged.
        let decoder = JSONDecoder()
        #expect(try decoder.decode(ColorRef.self, from: Data("\"accent\"".utf8))
                == .role(.accent))
        #expect(try decoder.decode(ColorRef.self, from: Data("\"#FF8800\"".utf8))
                == .hex(HexColor("#FF8800")!))
    }

    @Test("a colour that is neither role nor hex is rejected")
    func badColorRefThrows() {
        // Loudly, because it is in a preset the user is editing by hand — the
        // silent fallback belongs to theme overrides, not to structure.
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ColorRef.self, from: Data("\"chartreuse\"".utf8))
        }
    }

    // MARK: - Built-ins

    @Test("built-in names are unique")
    func builtInNamesAreUnique() {
        // The active preset is stored by name, so a duplicate would make which
        // one you get undefined.
        let names = BarPreset.builtIns.map(\.name)
        #expect(Set(names).count == names.count)
    }

    @Test("every built-in is marked as one")
    func builtInsAreFlagged() {
        // The flag is what makes them read-only; an unflagged built-in would be
        // editable in place and then shadowed forever by the stored copy.
        for preset in BarPreset.builtIns {
            #expect(preset.isBuiltIn, "'\(preset.name)' is not flagged built-in")
        }
    }

    @Test("the default preset name resolves to a built-in")
    func defaultNameResolves() {
        #expect(BarPreset.builtIns.contains { $0.name == BarPreset.defaultName })
    }

    @Test("every built-in shows something on both bars")
    func builtInsAreNotEmpty() {
        // A preset that renders two empty strips looks like the app crashed.
        for preset in BarPreset.builtIns {
            for (edge, layout) in [("top", preset.top), ("bottom", preset.bottom)] {
                let modules = ZoneSide.allCases
                    .flatMap { layout.pages($0) }
                    .flatMap(\.sections)
                    .flatMap(\.modules)
                #expect(!modules.isEmpty, "'\(preset.name)' \(edge) bar is empty")
            }
        }
    }

    @Test("duplicating clears the built-in flag")
    func duplicatingProducesUserPreset() {
        let copy = BarPreset.spaceman.duplicated(as: "Mine")
        #expect(!copy.isBuiltIn)
        #expect(copy.name == "Mine")
        #expect(copy.top == BarPreset.spaceman.top, "content is otherwise unchanged")
    }

    @Test("Spaceman actually uses slants")
    func spacemanHasSlants() {
        // It is the preset that demonstrates sections exist; without a slant it
        // is just Classic with fills. Both bars, both sides.
        for layout in [BarPreset.spaceman.top, BarPreset.spaceman.bottom] {
            for side in [ZoneSide.leading, .trailing] {
                let edges = layout.pages(side)
                    .flatMap(\.sections)
                    .flatMap { [$0.leadingEdge, $0.trailingEdge] }
                #expect(edges.contains { $0.style.isShared && $0.reservedWidth > 0 },
                        "\(side) zone should be slanted")
            }
        }
    }

    @Test("a vertical edge reserves nothing whatever width it holds")
    func verticalEdgeReservesNothing() {
        // Switching style must not lose the width the user already set, so the
        // width is kept and simply ignored.
        #expect(EdgeShape(style: .vertical, width: 20).reservedWidth == 0)
        #expect(EdgeShape(style: .gap, width: 20).reservedWidth == 20)
    }

    @Test("only slashes are shared boundaries")
    func onlySlashesAreShared() {
        #expect(EdgeStyle.downSlash.isShared)
        #expect(EdgeStyle.upSlash.isShared)
        #expect(!EdgeStyle.gap.isShared, "a gap separates rather than joins")
        #expect(!EdgeStyle.vertical.isShared)
    }

    @Test("edge style names carry no punctuation")
    func edgeStyleTitlesAreWords() {
        // They are picker labels, not ASCII art.
        for style in EdgeStyle.allCases {
            #expect(!style.title.contains("/"))
            #expect(!style.title.contains("\\"))
        }
    }

    @Test("Dense has a zone worth scrolling")
    func denseHasPages() {
        let hasMultiplePages = ZoneSide.allCases
            .contains { BarPreset.dense.top.pages($0).count > 1 }
        #expect(hasMultiplePages)
    }

    // MARK: - Zone access

    @Test("setting a zone's pages reads them back")
    func zoneAccessRoundTrips() {
        var layout = BarLayout()
        for side in ZoneSide.allCases {
            layout.setPages([BarPage([.clock])], for: side)
            #expect(layout.pages(side).count == 1)
        }
        // And each side is stored independently.
        #expect(layout.leading == layout.center)
        layout.setPages([], for: .center)
        #expect(layout.leading.count == 1)
        #expect(layout.center.isEmpty)
    }

    @Test("the module shorthand makes one unfilled section")
    func pageShorthand() {
        let page = BarPage([.clock, .date])
        #expect(page.sections.count == 1)
        #expect(page.sections[0].modules == [.clock, .date])
        #expect(page.sections[0].fill == nil)
    }
}


@Suite("Spaceman preset styling")
struct SpacemanPresetTests {

    /// Every slanted edge in the preset, both bars, both zones.
    private var slants: [EdgeShape] {
        [BarPreset.spaceman.top, BarPreset.spaceman.bottom]
            .flatMap { layout in ZoneSide.allCases.flatMap { layout.pages($0) } }
            .flatMap(\.sections)
            .flatMap { [$0.leadingEdge, $0.trailingEdge] }
            .filter { $0.style.isShared }
    }

    @Test("every slash leans the same way")
    func consistentDirection() {
        // So the two bars read as one system rather than mirroring each other
        // across the screen.
        #expect(!slants.isEmpty)
        #expect(slants.allSatisfy { $0.style == .upSlash })
    }

    @Test("both bars carry the treatment on both sides")
    func bothBarsStyled() {
        // The trailing zones used to trail off unfilled, which made the bottom
        // bar look unfinished beside the top one.
        for layout in [BarPreset.spaceman.top, BarPreset.spaceman.bottom] {
            for side in [ZoneSide.leading, .trailing] {
                let sections = layout.pages(side).flatMap(\.sections)
                #expect(!sections.isEmpty, "\(side) should have sections")
                #expect(sections.contains { $0.fill != nil }, "\(side) should be filled")
            }
        }
    }
}
