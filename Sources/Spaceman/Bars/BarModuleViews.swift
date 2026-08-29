import SwiftUI
import SpacemanCore

/// Everything a module needs to render and act. Passed down rather than reached
/// for globally, so a module is a pure function of context — which is what makes
/// the Settings preview able to render the same views against sample data.
@MainActor
struct BarContext {
    let state: BarState
    let preferences: Preferences
    let displayID: CGDirectDisplayID
    /// Set only by the Settings preview, so it can show a palette that is not
    /// the active one. A live bar leaves this nil and follows whatever palette
    /// is in force, re-read on every render.
    var paletteOverride: PalettePreset? = nil
    let onCycleLayout: (CGDirectDisplayID) -> Void
    let onRetile: () -> Void
    let onShrinkMaster: () -> Void
    let onGrowMaster: () -> Void

    var palette: PalettePreset {
        if let paletteOverride { return paletteOverride }
        return preferences.activePalette
    }

    /// A context whose actions do nothing, for the Settings preview.
    static func preview(state: BarState,
                        preferences: Preferences,
                        palette: PalettePreset) -> BarContext {
        BarContext(state: state, preferences: preferences, displayID: 0,
                   paletteOverride: palette,
                   onCycleLayout: { _ in }, onRetile: {},
                   onShrinkMaster: {}, onGrowMaster: {})
    }
}

enum BarTypography {
    static let font = Font.system(size: 11, weight: .medium, design: .rounded)
    /// Space between modules within a section.
    static let moduleSpacing: CGFloat = 8
}

/// One module's content. Deliberately unstyled — fill and text colour come from
/// the enclosing section, so the same module looks right inside a filled
/// powerline block and on bare bar background.
struct BarModuleView: View {
    let module: BarModule
    let context: BarContext
    /// The same object `context` carries, declared again so *this* view
    /// subscribes to it.
    ///
    /// `BarView` observing `BarState` is not enough: when the clock ticks,
    /// nothing about `BarZoneView`'s inputs changes — same pages, same height,
    /// same context struct holding the same closures — so SwiftUI is free to
    /// skip re-rendering the subtree, and the modules that read state never
    /// re-evaluate. The observation has to be where the state is read.
    @ObservedObject var state: BarState

    var body: some View {
        switch module {
        case .spaceLabel:
            SpaceDotsView(dots: context.state.spaceDots[context.displayID] ?? [],
                          palette: context.palette)

        case .clock:
            Text(context.state.clock).monospacedDigit()

        case .date:
            Text(context.state.date)

        case .battery:
            if let battery = context.state.battery {
                label(batteryIcon(battery), "\(battery.percent)%")
                    .foregroundStyle(battery.percent <= 15 && !battery.isCharging
                                     ? Theme.color(.danger, in: context.palette)
                                     : Color.primary)
            }

        case .layoutMode:
            Button { context.onCycleLayout(context.displayID) } label: {
                label("rectangle.split.2x1",
                      context.state.layoutModes[context.displayID]?.shortName ?? "—")
            }
            .buttonStyle(.plain)
            .help("Cycle layout (⌃⌥Space)")

        case .masterControls:
            HStack(spacing: 6) {
                Button(action: context.onShrinkMaster) { Image(systemName: "minus") }
                    .buttonStyle(.plain)
                    .help("Shrink master (⌃⌥-)")
                Button(action: context.onGrowMaster) { Image(systemName: "plus") }
                    .buttonStyle(.plain)
                    .help("Grow master (⌃⌥=)")
            }

        case .retileButton:
            Button(action: context.onRetile) {
                label("arrow.clockwise", "Tile")
            }
            .buttonStyle(.plain)
            .help("Re-tile now (⌃⌥T)")

        case .status:
            if !context.state.status.isEmpty {
                Text(context.state.status)
                    .foregroundStyle(Theme.color(.warn, in: context.palette))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    // The one module that may truncate — a status can be
                    // arbitrarily long, and sections size to their content, so
                    // without a ceiling one error message would push the whole
                    // zone off the end of the bar.
                    .frame(maxWidth: 280)
            }

        case .moverStatus:
            HStack(spacing: 5) {
                Circle()
                    .fill(context.state.moverReady
                          ? Theme.color(.good, in: context.palette)
                          : Theme.color(.warn, in: context.palette))
                    .frame(width: 6, height: 6)
                Text(context.state.moverName)
            }
            .help(context.state.moverReady
                  ? "Window mover ready"
                  : "Window mover unavailable — bars still work, tiling is paused")

        case .brand:
            HStack(spacing: 6) {
                BrandIcon.View(pointSize: 18)
                Text("Spaceman \(AppVersion.marketing)")
            }

        case .spacer:
            // A fixed gap rather than a flexible one: zones are sized to their
            // content, so a greedy spacer would push a zone to full bar width
            // and shove the other two off the end.
            Color.clear.frame(width: 16, height: 1)

        default:
            // A plugin's module, or nothing. Nothing is a normal outcome: a
            // preset may name a module from a plugin this build excludes, and
            // rendering an empty view leaves the preset intact so re-adding the
            // plugin brings it back.
            PluginSurface.shared.barContent(for: module)
        }
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
            Text(text)
        }
    }

    private func batteryIcon(_ battery: BatteryReading) -> String {
        if battery.isCharging { return "battery.100.bolt" }
        switch battery.percent {
        case ..<15:  return "battery.0"
        case ..<40:  return "battery.25"
        case ..<70:  return "battery.50"
        case ..<90:  return "battery.75"
        default:     return "battery.100"
        }
    }
}

/// One filled, larger dot for the current Space; dimmer smaller dots for the rest.
private struct SpaceDotsView: View {
    let dots: [SpaceDot]
    let palette: PalettePreset

    var body: some View {
        if dots.isEmpty {
            Text("—")
        } else {
            HStack(spacing: 5) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, dot in
                    Circle()
                        .fill(Theme.color(.accent, in: palette))
                        .opacity(dot.isCurrent ? 1 : 0.44)
                        .frame(width: dot.isCurrent ? 9 : 6,
                               height: dot.isCurrent ? 9 : 6)
                }
            }
            .help(help)
            .accessibilityLabel(help)
        }
    }

    private var help: String {
        guard let index = dots.firstIndex(where: \.isCurrent) else {
            return "\(dots.count) Spaces"
        }
        return "Space \(index + 1) of \(dots.count)"
    }
}

/// A section's modules in a row. The unit the geometry measures.
struct SectionContent: View {
    let section: BarSection
    let context: BarContext

    var body: some View {
        HStack(spacing: BarTypography.moduleSpacing) {
            ForEach(Array(section.modules.enumerated()), id: \.offset) { _, module in
                BarModuleView(module: module, context: context, state: context.state)
            }
        }
        .font(BarTypography.font)
        .foregroundStyle(textColor)
    }

    /// A filled section defaults its text to the background colour, because a
    /// fill is usually accent-coloured and label-on-accent is unreadable. An
    /// explicit `text` still wins.
    private var textColor: Color {
        if let text = section.text {
            return Theme.color(text, in: context.palette)
        }
        if section.fill != nil {
            return Theme.color(.background, in: context.palette)
        }
        return Theme.color(.text, in: context.palette)
    }
}
