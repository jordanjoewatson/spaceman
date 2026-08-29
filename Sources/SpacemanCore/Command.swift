import CoreGraphics
import Foundation

/// A single thing the user can ask the app to do.
///
/// **Deliberately a closed set.** One grammar backs the config file, the URL
/// scheme and the menu-bar item, so the three can never drift apart — and a
/// named sequence of built-in verbs is data, not code, which keeps the file
/// trivially reviewable.
public enum Command: Equatable, Sendable {
    case setLayout(LayoutMode)
    case cycleLayout
    case retile
    /// Absolute master ratio, 0.1...0.9 (the Go version's master range).
    case setMaster(CGFloat)
    /// Relative change to the master ratio.
    case adjustMaster(CGFloat)
    case setGap(CGFloat)
    case setAnimation(Bool)

    public var describedName: String {
        switch self {
        case .setLayout(let mode):   return "layout \(mode.rawValue)"
        case .cycleLayout:           return "layout next"
        case .retile:                return "retile"
        case .setMaster(let value):  return "master \(value)"
        case .adjustMaster(let d):   return "master \(d >= 0 ? "+" : "")\(d)"
        case .setGap(let value):     return "gap \(value)"
        case .setAnimation(let on):  return "animation \(on ? "on" : "off")"
        }
    }
}

public enum CommandParseError: Error, Equatable, CustomStringConvertible {
    case empty
    case unknownVerb(String)
    case unknownLayout(String)
    case missingArgument(verb: String)
    case badNumber(String)
    case outOfRange(value: CGFloat, min: CGFloat, max: CGFloat)

    public var description: String {
        switch self {
        case .empty:
            return "empty command"
        case .unknownVerb(let v):
            return "unknown command '\(v)' (expected: layout, retile, master, gap, animation)"
        case .unknownLayout(let l):
            return "unknown layout '\(l)' (expected: "
                + LayoutMode.allCases.map { $0.shortName.lowercased() }.joined(separator: ", ")
                + ", next)"
        case .missingArgument(let verb):
            return "'\(verb)' needs an argument"
        case .badNumber(let s):
            return "'\(s)' is not a number"
        case .outOfRange(let value, let min, let max):
            return "\(value) is outside \(min)...\(max)"
        }
    }
}

extension Command {
    /// Parse one command from a line of text.
    ///
    /// The grammar is intentionally tiny and whitespace-separated so that a
    /// config file, a URL query and a menu title can all use the same strings:
    ///
    ///     layout bsp | layout next | retile
    ///     master 0.6 | master +0.05 | master -0.05
    ///     gap 12     | animation off
    public static func parse(_ text: String) throws -> Command {
        let parts = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let verb = parts.first?.lowercased() else { throw CommandParseError.empty }
        let argument = parts.count > 1 ? parts[1] : nil

        switch verb {
        case "retile":
            return .retile

        case "layout":
            guard let argument else { throw CommandParseError.missingArgument(verb: verb) }
            if argument.lowercased() == "next" { return .cycleLayout }
            guard let mode = LayoutMode(userInput: argument) else {
                throw CommandParseError.unknownLayout(argument)
            }
            return .setLayout(mode)

        case "master":
            guard let argument else { throw CommandParseError.missingArgument(verb: verb) }
            let value = try number(argument)
            // A leading sign means "relative"; a bare number means "absolute".
            if argument.hasPrefix("+") || argument.hasPrefix("-") {
                return .adjustMaster(value)
            }
            try range(value, min: 0.1, max: 0.9)
            return .setMaster(value)

        case "gap":
            guard let argument else { throw CommandParseError.missingArgument(verb: verb) }
            let value = try number(argument)
            try range(value, min: 0, max: 200)
            return .setGap(value)

        case "animation":
            guard let argument else { throw CommandParseError.missingArgument(verb: verb) }
            switch argument.lowercased() {
            case "on", "true", "1":   return .setAnimation(true)
            case "off", "false", "0": return .setAnimation(false)
            default: throw CommandParseError.badNumber(argument)
            }

        default:
            throw CommandParseError.unknownVerb(verb)
        }
    }

    private static func number(_ text: String) throws -> CGFloat {
        guard let value = Double(text) else { throw CommandParseError.badNumber(text) }
        return CGFloat(value)
    }

    private static func range(_ value: CGFloat, min: CGFloat, max: CGFloat) throws {
        guard value >= min, value <= max else {
            throw CommandParseError.outOfRange(value: value, min: min, max: max)
        }
    }
}

/// A user-named sequence of commands.
public struct CommandScript: Equatable, Sendable {
    public let name: String
    public let commands: [Command]

    public init(name: String, commands: [Command]) {
        self.name = name
        self.commands = commands
    }
}

/// What the user's config file decodes into, plus the errors worth showing them.
public struct CommandSet: Sendable {
    public let scripts: [CommandScript]
    /// Problems found while parsing. Reported rather than thrown: one bad line
    /// should not silently discard the user's other, working commands.
    public let problems: [String]

    public init(scripts: [CommandScript], problems: [String]) {
        self.scripts = scripts
        self.problems = problems
    }

    public func script(named name: String) -> CommandScript? {
        scripts.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Decode from the on-disk format:
    ///
    ///     { "commands": { "coding": ["layout master", "master 0.65"] } }
    public static func decode(from data: Data) throws -> CommandSet {
        struct File: Decodable { let commands: [String: [String]] }
        let file = try JSONDecoder().decode(File.self, from: data)

        var scripts: [CommandScript] = []
        var problems: [String] = []

        // Sorted so the menu order is stable between launches rather than
        // following dictionary hashing.
        for name in file.commands.keys.sorted() {
            var parsed: [Command] = []
            for line in file.commands[name] ?? [] {
                do {
                    parsed.append(try Command.parse(line))
                } catch {
                    problems.append("\(name): \(error)")
                }
            }
            if !parsed.isEmpty {
                scripts.append(CommandScript(name: name, commands: parsed))
            }
        }
        return CommandSet(scripts: scripts, problems: problems)
    }
}
