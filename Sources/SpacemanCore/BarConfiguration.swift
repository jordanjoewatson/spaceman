import Foundation

/// The bar layout model: what each bar shows, where, and how it is painted.
///
/// The shape mirrors the Go version's zone system (`internal/ui/bar/config.go`,
/// `sections.go`), because that model earns its complexity:
///
///     bar → zone (leading | center | trailing)
///           → page   (scrolled under the pointer, one visible at a time)
///             → section (a fill + a shaped edge, grouping modules)
///               → module (the actual content)
///
/// Pages are why a bottom bar can carry minimized windows *and* clipboard chips
/// without either being hidden behind a mode switch — you scroll the zone that
/// interests you and the other two stay put. Sections are why a bar can read as
/// a powerline rather than a row of pills: adjacent sections share one boundary,
/// so their fills meet along a single diagonal with no seam.
///
/// Everything here is `Codable` and lives in this target, with no AppKit, so a
/// preset is data — round-trippable, diffable, and testable without a screen.

/// How a section's edge is cut.
///
/// `gap` is the one that is not a shape: it separates two sections by empty bar
/// instead of joining them, which is why a boundary cannot always be a single
/// shared line — see `BarGeometry`.
public enum EdgeStyle: String, Codable, CaseIterable, Sendable {
    case vertical, downSlash, upSlash, gap

    public var title: String {
        switch self {
        case .vertical:  return "Vertical"
        case .downSlash: return "Down Slash"
        case .upSlash:   return "Up Slash"
        case .gap:       return "Gap"
        }
    }

    /// Whether `width` means anything for this style.
    public var usesWidth: Bool { self != .vertical }

    /// True when the two sections either side share one boundary line.
    public var isShared: Bool { self == .downSlash || self == .upSlash }
}

/// One side of a section.
public struct EdgeShape: Codable, Equatable, Sendable {
    public var style: EdgeStyle
    /// Slant width, or gap width. Ignored when the style is `vertical`.
    public var width: Double
    /// What to paint in a gap. `gap` only — a slash has no region of its own,
    /// being a line the two neighbours share.
    ///
    /// nil leaves the gap genuinely empty, showing the bar through it, which is
    /// what "gap" usually means. Setting it makes the gap a divider or a spacer
    /// block without needing a module-less section to hold the colour.
    public var fill: ColorRef?

    public init(style: EdgeStyle = .vertical, width: Double = 0, fill: ColorRef? = nil) {
        self.style = style
        self.width = width
        self.fill = fill
    }

    public static let vertical = EdgeShape()

    /// The horizontal room this edge takes. A vertical edge takes none however
    /// wide it claims to be, so a user can flip between styles without losing
    /// the width they had set.
    public var reservedWidth: Double { style.usesWidth ? width : 0 }
}

/// A colour named either by theme role or literally.
///
/// Roles are the better choice and the reason they come first: a section filled
/// with `.role(.accent)` follows the user's system accent and their dark mode,
/// while a hex is frozen. Hex exists because a powerline preset wants a specific
/// ramp of colours that no set of semantic roles describes.
public enum ColorRef: Codable, Equatable, Sendable {
    case role(ThemeRole)
    case hex(HexColor)

    /// Encoded as one string — `"accent"` or `"#FF6600"` — rather than a tagged
    /// object. A preset is stored as JSON in a preference, so it is something a
    /// person may well read and edit by hand; `"fill": "accent"` is worth the
    /// custom coding over `"fill": {"role": {"_0": "accent"}}`.
    ///
    /// This is also the exact grammar the Go config accepted, so a section
    /// definition can be copied across unchanged.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        if let role = ThemeRole(rawValue: text) {
            self = .role(role)
        } else if let hex = HexColor(text) {
            self = .hex(hex)
        } else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "'\(text)' is neither a theme role nor a hex colour"))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .role(let role): try container.encode(role.rawValue)
        case .hex(let hex):   try container.encode(hex.hexString)
        }
    }
}

/// A group of modules sharing a fill and a pair of shaped edges.
public struct BarSection: Codable, Equatable, Sendable {
    public var modules: [BarModule]
    /// nil paints nothing — the section is a plain run of modules.
    public var fill: ColorRef?
    /// nil uses the bar's normal text colour.
    public var text: ColorRef?
    public var leadingEdge: EdgeShape
    public var trailingEdge: EdgeShape

    public init(modules: [BarModule],
                fill: ColorRef? = nil,
                text: ColorRef? = nil,
                leadingEdge: EdgeShape = .vertical,
                trailingEdge: EdgeShape = .vertical) {
        self.modules = modules
        self.fill = fill
        self.text = text
        self.leadingEdge = leadingEdge
        self.trailingEdge = trailingEdge
    }
}

/// One screenful of a zone. A zone with more than one page scrolls.
public struct BarPage: Codable, Equatable, Sendable {
    public var sections: [BarSection]

    public init(sections: [BarSection]) {
        self.sections = sections
    }

    /// The common case: one unfilled section of modules.
    public init(_ modules: [BarModule]) {
        self.sections = [BarSection(modules: modules)]
    }
}

/// Where in a bar a zone sits. Named by edge rather than left/right so the
/// meaning survives a right-to-left layout.
public enum ZoneSide: String, Codable, CaseIterable, Sendable {
    case leading, center, trailing

    public var title: String {
        switch self {
        case .leading:  return "Leading"
        case .center:   return "Center"
        case .trailing: return "Trailing"
        }
    }
}

/// One bar's full appearance and content.
public struct BarLayout: Codable, Equatable, Sendable {
    public var height: Double
    /// Inset from the screen edges and shadowed. Flush bars get a hairline on
    /// their inner edge instead — with no gap, that rule is the only thing
    /// separating the bar from the window behind it.
    public var floating: Bool
    public var cornerRadius: Double
    /// An `NSVisualEffectView.Material` name; see `BarMaterial`.
    public var material: String
    /// Inset between the bar's content and its left and right ends. Also how far
    /// an edge zone's fill bleeds outward, so a filled section still reaches the
    /// bar end however wide this is.
    public var edgePadding: Double
    public var leading: [BarPage]
    public var center: [BarPage]
    public var trailing: [BarPage]

    public init(height: Double = 26,
                floating: Bool = false,
                cornerRadius: Double = 0,
                material: String = "hudWindow",
                edgePadding: Double = 10,
                leading: [BarPage] = [],
                center: [BarPage] = [],
                trailing: [BarPage] = []) {
        self.height = height
        self.floating = floating
        self.cornerRadius = cornerRadius
        self.material = material
        self.edgePadding = edgePadding
        self.leading = leading
        self.center = center
        self.trailing = trailing
    }

    public func pages(_ side: ZoneSide) -> [BarPage] {
        switch side {
        case .leading:  return leading
        case .center:   return center
        case .trailing: return trailing
        }
    }

    public mutating func setPages(_ pages: [BarPage], for side: ZoneSide) {
        switch side {
        case .leading:  leading = pages
        case .center:   center = pages
        case .trailing: trailing = pages
        }
    }
}

/// A named pair of bar layouts the user can switch between.
///
/// Presets follow the Terminal.app profile model: a set ships with the app and
/// is read-only, and customising one duplicates it. That keeps the built-ins
/// repairable — "go back to Default" always works — and means a preset can be
/// improved in a later version without silently overwriting someone's edits.
public struct BarPreset: Preset {
    public var name: String
    public var top: BarLayout
    public var bottom: BarLayout
    /// True for the presets compiled into the app.
    public var isBuiltIn: Bool

    public init(name: String, top: BarLayout, bottom: BarLayout, isBuiltIn: Bool = false) {
        self.name = name
        self.top = top
        self.bottom = bottom
        self.isBuiltIn = isBuiltIn
    }

    /// A user-owned copy, which is what "customise a built-in" produces.
    public func duplicated(as newName: String) -> BarPreset {
        BarPreset(name: newName, top: top, bottom: bottom, isBuiltIn: false)
    }
}

// MARK: - Built-in presets

public extension BarPreset {

    /// The presets compiled into the app. Declaration order is the order they
    /// appear in Settings.
    static let builtIns: [BarPreset] = [.spaceman, .minimal]

    static var defaultName: String { spaceman.name }

    /// A restrained configuration with no shaped or coloured sections.
    static let minimal = BarPreset(
        name: "Minimal",
        top: BarLayout(
            leading: [BarPage([.spaceLabel])],
            trailing: [BarPage([.battery, .clock])]
        ),
        bottom: BarLayout(
            leading: [BarPage([.layoutMode, .masterControls, .retileButton])],
            center: [BarPage([BarModule("clipboard.history")])],
            trailing: [BarPage([.status, .moverStatus])]
        ),
        isBuiltIn: true
    )

    /// Source compatibility for callers that used the old built-in name.
    static var classic: BarPreset { minimal }

    /// The project's signature configuration, promoted from the user-tuned
    /// "Spaceman Copy" preset. Orange powerline sections frame the information
    /// modules, with the top bar carrying identity/time and the bottom bar
    /// carrying layout/status controls.
    static let spaceman = BarPreset(
        name: "Spaceman",
        top: BarLayout(
            leading: [BarPage(sections: [
                BarSection(modules: [.brand],
                           fill: .hex(HexColor("#D08100")!), text: .role(.background),
                           trailingEdge: EdgeShape(style: .upSlash, width: 12)),
                BarSection(modules: [.date],
                           fill: .role(.warn),
                           trailingEdge: EdgeShape(style: .upSlash, width: 12)),
            ])],
            center: [BarPage(sections: [])],
            trailing: [BarPage(sections: [
                BarSection(modules: [.battery, BarModule("pomodoro.timer")],
                           fill: .hex(HexColor("#D08100")!), text: .role(.background),
                           leadingEdge: EdgeShape(style: .downSlash, width: 12),
                           trailingEdge: EdgeShape(style: .downSlash, width: 12)),
                BarSection(modules: [.clock],
                           fill: .role(.warn), text: .role(.background),
                           leadingEdge: EdgeShape(style: .downSlash, width: 12)),
            ])]
        ),
        bottom: BarLayout(
            leading: [BarPage(sections: [
                BarSection(modules: [.layoutMode],
                           fill: .hex(HexColor("#D08100")!), text: .role(.background),
                           trailingEdge: EdgeShape(style: .downSlash, width: 12)),
                BarSection(modules: [.spacer],
                           fill: .role(.warn),
                           trailingEdge: EdgeShape(style: .downSlash, width: 12)),
            ])],
            center: [BarPage(sections: [
                BarSection(modules: [BarModule("clipboard.history")],
                           text: .role(.background),
                           leadingEdge: EdgeShape(style: .upSlash, width: 12),
                           trailingEdge: EdgeShape(style: .upSlash, width: 12)),
            ])],
            trailing: [BarPage(sections: [
                BarSection(modules: [.status],
                           fill: .role(.warn),
                           leadingEdge: EdgeShape(style: .upSlash, width: 12)),
                BarSection(modules: [.moverStatus],
                           fill: .hex(HexColor("#D08100")!), text: .role(.background),
                           leadingEdge: EdgeShape(style: .upSlash, width: 12)),
            ])]
        ),
        isBuiltIn: true
    )

    /// The former floating Minimal preset. Retained as data for source
    /// compatibility, but no longer offered in the built-in preset list.
    static let floatingMinimal = BarPreset(
        name: "Floating Minimal",
        top: BarLayout(height: 24, floating: true, cornerRadius: 11,
                       material: "popover",
                       center: [BarPage([.clock])]),
        bottom: BarLayout(height: 24, floating: true, cornerRadius: 11,
                          material: "popover",
                          leading: [BarPage([.layoutMode])],
                          trailing: [BarPage([.status])]),
        isBuiltIn: true
    )

    /// Everything, using pages so it still fits: each zone carries more than one
    /// screenful and scrolls under the pointer.
    static let dense = BarPreset(
        name: "Dense",
        top: BarLayout(
            height: 28,
            leading: [BarPage([.spaceLabel]), BarPage([.brand])],
            center: [BarPage([.clock]), BarPage([.date])],
            trailing: [BarPage([.battery]), BarPage([.clock, .date])]
        ),
        bottom: BarLayout(
            height: 28,
            leading: [BarPage([.layoutMode, .retileButton]),
                      BarPage([.masterControls, .retileButton])],
            center: [BarPage([BarModule("clipboard.history")])],
            trailing: [BarPage([.status, .moverStatus]), BarPage([.moverStatus])]
        ),
        isBuiltIn: true
    )
}
