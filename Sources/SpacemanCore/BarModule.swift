import Foundation

/// One piece of bar content, identified by name rather than by case.
///
/// An enum would close the set to what the core knows about, and plugins have to
/// be able to contribute modules — clipboard history is bar content the core
/// cannot enumerate. An identifier also survives the plugin being compiled out:
/// the preset still references `clipboard.history`, the bar renders nothing for
/// it, and adding the plugin back restores it. An enum would fail to decode the
/// preset entirely.
///
/// Namespaced by convention: core modules are bare (`clock`), plugin modules are
/// prefixed with the plugin name (`clipboard.history`).
public struct BarModule: Codable, Equatable, Hashable, Sendable {
    public let id: String

    public init(_ id: String) {
        self.id = id
    }

    /// Encoded as the bare identifier, so a stored preset reads as
    /// `"modules": ["clock", "clipboard.history"]`.
    public init(from decoder: any Decoder) throws {
        id = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(id)
    }
}

// MARK: - Core modules

public extension BarModule {
    static let spaceLabel     = BarModule("spaceLabel")
    static let clock          = BarModule("clock")
    static let date           = BarModule("date")
    static let battery        = BarModule("battery")
    static let layoutMode     = BarModule("layoutMode")
    static let masterControls = BarModule("masterControls")
    static let retileButton   = BarModule("retileButton")
    static let status         = BarModule("status")
    static let moverStatus    = BarModule("moverStatus")
    static let brand          = BarModule("brand")
    static let spacer         = BarModule("spacer")

    /// Declaration order is the order the editor's picker lists them.
    static let core: [BarModuleDescriptor] = [
        .init(.spaceLabel, "Spaces", "One dot per Space on this display"),
        .init(.clock, "Clock", "Time, in your system format"),
        .init(.date, "Date", "Weekday, day and month"),
        .init(.battery, "Battery", "Charge level, red below 15%"),
        .init(.layoutMode, "Layout", "Active layout — click to cycle"),
        .init(.masterControls, "Master ±", "Grow and shrink the master pane"),
        .init(.retileButton, "Re-tile", "Re-tile the current Space"),
        .init(.status, "Status Message", "Last error or notice, for a few seconds"),
        .init(.moverStatus, "Mover Status", "Which window mover is in use, and whether it works"),
        .init(.brand, "Spaceman", "App name, icon and version"),
        .init(.spacer, "Spacer", "A fixed 16pt space"),
    ]
}

/// What a module is called and what it shows, for the editor's picker.
///
/// Separate from `BarModule` because a plugin supplies its own: the identifier
/// is the stable thing that goes in a preset, the description is presentation.
public struct BarModuleDescriptor: Sendable, Identifiable {
    public let module: BarModule
    public let title: String
    public let summary: String

    public var id: String { module.id }

    public init(_ module: BarModule, _ title: String, _ summary: String) {
        self.module = module
        self.title = title
        self.summary = summary
    }
}
