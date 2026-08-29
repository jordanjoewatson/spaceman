import Testing
import CoreGraphics
import Foundation
@testable import SpacemanCore

@Suite("Command parsing")
struct CommandParseTests {

    @Test("layout by name")
    func layoutByName() throws {
        #expect(try Command.parse("layout bsp") == .setLayout(.bsp))
        #expect(try Command.parse("layout monocle") == .setLayout(.monocle))
    }

    @Test("layout accepts the spellings a person would actually type")
    func layoutAliases() throws {
        // The raw value is `masterStack`; nobody hand-writes camel case in a
        // config file, and rejecting "master" is the most likely reason a custom
        // command would silently fail to load.
        #expect(try Command.parse("layout master") == .setLayout(.masterStack))
        #expect(try Command.parse("layout cols") == .setLayout(.columns))
        #expect(try Command.parse("layout mono") == .setLayout(.monocle))
        #expect(try Command.parse("layout MASTER") == .setLayout(.masterStack))
    }

    @Test("layout next cycles")
    func layoutNext() throws {
        #expect(try Command.parse("layout next") == .cycleLayout)
    }

    @Test("retile takes no argument")
    func retile() throws {
        #expect(try Command.parse("retile") == .retile)
    }

    @Test("a bare number sets the master ratio absolutely")
    func masterAbsolute() throws {
        #expect(try Command.parse("master 0.6") == .setMaster(0.6))
    }

    @Test("a signed number adjusts the master ratio relatively")
    func masterRelative() throws {
        // The sign is the whole distinction, so both directions are covered.
        #expect(try Command.parse("master +0.05") == .adjustMaster(0.05))
        #expect(try Command.parse("master -0.05") == .adjustMaster(-0.05))
    }

    @Test("animation accepts on/off spellings")
    func animation() throws {
        #expect(try Command.parse("animation on") == .setAnimation(true))
        #expect(try Command.parse("animation off") == .setAnimation(false))
        #expect(try Command.parse("animation 1") == .setAnimation(true))
    }

    @Test("parsing is case- and whitespace-insensitive")
    func lenientFormatting() throws {
        #expect(try Command.parse("  LAYOUT   bsp  ") == .setLayout(.bsp))
    }

    @Test("an empty line is an error, not a silent no-op")
    func emptyIsAnError() {
        #expect(throws: CommandParseError.empty) { try Command.parse("   ") }
    }

    @Test("an unknown verb names what was expected")
    func unknownVerb() {
        #expect(throws: CommandParseError.unknownVerb("frobnicate")) {
            try Command.parse("frobnicate 3")
        }
    }

    @Test("an unknown layout is rejected")
    func unknownLayout() {
        #expect(throws: CommandParseError.unknownLayout("spiral")) {
            try Command.parse("layout spiral")
        }
    }

    @Test("a missing argument is reported against its verb")
    func missingArgument() {
        #expect(throws: CommandParseError.missingArgument(verb: "layout")) {
            try Command.parse("layout")
        }
        #expect(throws: CommandParseError.missingArgument(verb: "master")) {
            try Command.parse("master")
        }
    }

    @Test("a non-numeric argument is rejected")
    func badNumber() {
        #expect(throws: CommandParseError.badNumber("wide")) { try Command.parse("master wide") }
    }

    @Test("an out-of-range absolute master ratio is rejected")
    func masterOutOfRange() {
        // Values outside 0.1...0.9 would squeeze the stack out of existence.
        #expect(throws: CommandParseError.outOfRange(value: 5, min: 0.1, max: 0.9)) {
            try Command.parse("master 5")
        }
    }

    @Test("a negative gap is rejected")
    func negativeGap() {
        #expect(throws: CommandParseError.outOfRange(value: -1, min: 0, max: 200)) {
            try Command.parse("gap -1")
        }
    }
}

@Suite("CommandSet decoding")
struct CommandSetTests {

    private func json(_ string: String) -> Data { Data(string.utf8) }

    @Test("a well-formed file decodes into named scripts")
    func decodesScripts() throws {
        let set = try CommandSet.decode(from: json("""
        { "commands": { "coding": ["layout master", "master 0.65", "retile"] } }
        """))
        #expect(set.scripts.count == 1)
        #expect(set.scripts[0].name == "coding")
        #expect(set.scripts[0].commands == [.setLayout(.masterStack), .setMaster(0.65), .retile])
        #expect(set.problems.isEmpty)
    }

    @Test("one bad line does not discard the rest of the script")
    func partialFailureIsTolerated() throws {
        // The user should get the commands that work plus a note about the one
        // that does not, rather than losing everything to a typo.
        let set = try CommandSet.decode(from: json("""
        { "commands": { "coding": ["layout master", "layout spiral", "retile"] } }
        """))
        #expect(set.scripts.count == 1)
        #expect(set.scripts[0].commands == [.setLayout(.masterStack), .retile])
        #expect(set.problems.count == 1)
        #expect(set.problems[0].contains("coding"))
    }

    @Test("a script with no valid commands is dropped but reported")
    func fullyInvalidScriptIsDropped() throws {
        let set = try CommandSet.decode(from: json("""
        { "commands": { "broken": ["nope"] } }
        """))
        #expect(set.scripts.isEmpty)
        #expect(set.problems.count == 1)
    }

    @Test("scripts are ordered deterministically")
    func stableOrdering() throws {
        // Menu order must not shuffle between launches with dictionary hashing.
        let set = try CommandSet.decode(from: json("""
        { "commands": { "zebra": ["retile"], "alpha": ["retile"], "mid": ["retile"] } }
        """))
        #expect(set.scripts.map(\.name) == ["alpha", "mid", "zebra"])
    }

    @Test("lookup by name is case-insensitive")
    func caseInsensitiveLookup() throws {
        let set = try CommandSet.decode(from: json("""
        { "commands": { "Coding": ["retile"] } }
        """))
        #expect(set.script(named: "coding") != nil)
        #expect(set.script(named: "CODING") != nil)
        #expect(set.script(named: "nope") == nil)
    }

    @Test("malformed JSON throws rather than yielding a silent empty set")
    func malformedJSONThrows() {
        #expect(throws: (any Error).self) {
            try CommandSet.decode(from: json("{ not json"))
        }
    }

    @Test("an empty commands object is valid and yields nothing")
    func emptyIsValid() throws {
        let set = try CommandSet.decode(from: json(#"{ "commands": {} }"#))
        #expect(set.scripts.isEmpty)
        #expect(set.problems.isEmpty)
    }
}
