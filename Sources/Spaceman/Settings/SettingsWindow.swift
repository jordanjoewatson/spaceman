import AppKit
import SwiftUI
import SpacemanCore

/// The Settings window, opened from the status menu with ⌘,.
///
/// Hand-built rather than SwiftUI's `Settings` scene: that scene belongs to the
/// SwiftUI `App` lifecycle, and this app is an `NSApplicationDelegate` running
/// at `.accessory` activation policy. The window itself is still SwiftUI.
///
/// Being an agent app, opening a window means activating first — with no Dock
/// tile and no menu bar of our own, nothing else will bring it forward.
@MainActor
final class SettingsWindowController {

    private var window: NSWindow?
    private let preferences: Preferences

    init(preferences: Preferences) {
        self.preferences = preferences
    }

    /// Comfortable size, and the smallest the panes stay usable at.
    private static let idealSize = CGSize(width: 980, height: 720)
    private static let minimumSize = CGSize(width: 720, height: 480)

    func show() {
        let created = window == nil
        if window == nil { window = makeWindow() }
        guard let window else { return }
        NSApp.activate()
        if created { window.center() }
        clampToScreen(window)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Self.idealSize),
            // Resizable, because the alternative is a window that is wrong on
            // some displays and cannot be corrected.
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spaceman Settings"

        // Empty sizing options: SwiftUI must not drive the window size.
        // A grouped Form's ideal height is the whole form. NSHostingView
        // would grow the window to match, and on macOS height grows upward,
        // which is how the sidebar vanished off the top of the screen.
        let hosting = NSHostingView(rootView: SettingsView(preferences: preferences,
                                                           surface: .shared))
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(Self.idealSize)

        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.minimumSize
        // Come to the user rather than dragging the user to the window.
        // Without this, activating a window that was left on another Space
        // switches Spaces to reach it — which is exactly what a summoned panel
        // must not do. `.moveToActiveSpace` brings it here instead.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.setFrameAutosaveName("SpacemanSettings")
        return window
    }

    /// Shrink the window to fit the display it will open on.
    ///
    /// A restored frame from a larger monitor, or a laptop screen smaller than
    /// the ideal size, would otherwise put the bottom of the window — and the
    /// controls on it — past the edge of the screen with no way to reach them.
    private func clampToScreen(_ window: NSWindow) {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(max(frame.width, Self.minimumSize.width), visible.width)
        frame.size.height = min(max(frame.height, Self.minimumSize.height), visible.height)
        // A previous SwiftUI-driven resize grew the window upward past the
        // menu bar. Pull the title bar back onto the display.
        if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
        if frame.minY < visible.minY { frame.origin.y = visible.minY }
        if frame.minX < visible.minX { frame.origin.x = visible.minX }
        if frame.maxX > visible.maxX { frame.origin.x = visible.maxX - frame.width }
        window.setFrame(frame, display: true)
    }
}

/// Which pane the sidebar has selected.
private enum SettingsPane: Hashable {
    case tiling, bars, palette, commands
    /// A plugin's own pane, by plugin name.
    case plugin(String)
}

/// Sidebar and detail, following System Settings since Ventura rather than a row
/// of tabs.
///
/// The shape earns itself here: plugins contribute panes, so the list is not
/// fixed at compile time, and tabs would either overflow or need scrolling. A
/// sidebar takes a "Plugins" section heading naturally, which also makes it
/// obvious *why* those entries exist and that they come and go with the build.
private struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var surface: PluginSurface

    @State private var selection: SettingsPane? = .tiling

    var body: some View {
        // A plain split, not NavigationSplitView. That container adds a
        // toolbar and then scrolls the selected row to the top of a viewport
        // that includes the title bar — which is why Tiling…Swap vanished
        // upward and Focus Timer sat half-clipped under the chrome.
        HStack(spacing: 0) {
            List(selection: $selection) {
                Section {
                    Label("Tiling", systemImage: "rectangle.split.2x1")
                        .tag(SettingsPane.tiling)
                    Label("Bars", systemImage: "menubar.rectangle")
                        .tag(SettingsPane.bars)
                    Label("Palette", systemImage: "swatchpalette")
                        .tag(SettingsPane.palette)
                    Label("Shortcuts", systemImage: "keyboard")
                        .tag(SettingsPane.commands)
                }

                if !surface.settingsPanes.isEmpty {
                    Section("Plugins") {
                        ForEach(surface.settingsPanes, id: \.name) { pane in
                            Label(pane.title, systemImage: "puzzlepiece.extension")
                                .tag(SettingsPane.plugin(pane.name))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 200)

            Divider()

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case .tiling:
            TilingPane(preferences: preferences).padding(12)
        case .bars:
            BarsPane(preferences: preferences)
        case .palette:
            PalettePane(preferences: preferences)
        case .commands:
            ShortcutsPane(preferences: preferences,
                          commands: ShortcutBindings.registered)
        case .plugin(let name):
            if let pane = surface.settingsPanes.first(where: { $0.name == name }) {
                PluginSettingsPane(pane: pane)
            }
        case nil:
            ContentUnavailableView("Settings", systemImage: "gearshape")
        }
    }
}

// MARK: - Plugins

/// A plugin's pane: what it is, its shortcuts, then its own controls.
///
/// The header is built by the app from what every plugin must declare, so the
/// panes stay consistent and a plugin with nothing to configure still has a
/// place in Settings rather than inventing its own "no settings" wording.
private struct PluginSettingsPane: View {
    let pane: PluginSurface.SettingsPane

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pane.title).font(.title3)
                Text(pane.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !pane.shortcuts.isEmpty {
                GroupBox("Shortcuts") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(pane.shortcuts, id: \.chord) { shortcut in
                            HStack(spacing: 10) {
                                Text(shortcut.chord)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(width: 70, alignment: .leading)
                                    .foregroundStyle(.secondary)
                                Text(shortcut.desc).font(.caption)
                                Spacer()
                            }
                        }
                        Text("Change these in Settings ▸ Shortcuts.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.top, 2)
                    }
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let content = pane.content {
                content()
            } else {
                Text("This plugin has nothing to configure.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Tiling

private struct TilingPane: View {
    @ObservedObject var preferences: Preferences

    var body: some View {
        Form {
            Picker("Default layout", selection: Binding(
                get: { preferences.defaultLayout },
                set: { preferences[Defaults.defaultLayout] = $0.rawValue }
            )) {
                ForEach(LayoutMode.allCases, id: \.self) { mode in
                    Text(mode.shortName.capitalized).tag(mode)
                }
            }
            .help("The layout a Space starts in. Existing Spaces keep theirs.")

            Slider(value: preferences.binding(Defaults.gap), in: 0...48, step: 1) {
                Text("Gap between windows")
            }
            valueLabel(preferences[Defaults.gap], unit: "pt")

            Slider(value: preferences.binding(Defaults.outerGap), in: 0...48, step: 1) {
                Text("Gap at screen edge")
            }
            valueLabel(preferences[Defaults.outerGap], unit: "pt")

            Slider(value: preferences.binding(Defaults.masterRatio), in: 0.1...0.9, step: 0.05) {
                Text("Master width")
            }
            valueLabel(preferences[Defaults.masterRatio] * 100, unit: "%")

            Slider(value: preferences.binding(Defaults.zoomFraction), in: 0.2...1.0, step: 0.05) {
                Text("Zoomed window size")
            }
            valueLabel(preferences[Defaults.zoomFraction] * 100, unit: "%")

            Section("Focus") {
                Toggle("Focus follows mouse", isOn: Binding(
                    get: { preferences[Defaults.followMouse] },
                    set: { preferences[Defaults.followMouse] = $0 }
                ))
                .help("Also on the menu-bar item as Auto focus")

                if preferences[Defaults.followMouse] {
                    Slider(value: preferences.binding(Defaults.hoverSeconds),
                           in: 0...1, step: 0.05) {
                        Text("Wait before switching")
                    }
                    valueLabel(preferences[Defaults.hoverSeconds] * 1000, unit: "ms")
                }
            }

            Section {
                Toggle("Animate window moves", isOn: Binding(
                    get: { preferences[Defaults.animationEnabled] },
                    set: { preferences[Defaults.animationEnabled] = $0 }
                ))
                .disabled(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)

                if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    Text("Turned off system-wide by Reduce Motion in Accessibility settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Slider(value: preferences.binding(Defaults.animationDuration),
                           in: 0.05...0.5, step: 0.01) {
                        Text("Duration")
                    }
                    valueLabel(preferences[Defaults.animationDuration] * 1000, unit: "ms")
                }
            }
        }
        .formStyle(.grouped)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Sliders read as a guess without the number they're producing.
private func valueLabel(_ value: Double, unit: String) -> some View {
    Text("\(Int(value.rounded()))\(unit)")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 52, alignment: .trailing)
}
