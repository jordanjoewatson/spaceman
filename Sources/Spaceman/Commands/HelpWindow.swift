import AppKit
import SwiftUI
import PluginKit
import SpacemanCore

/// The cheat sheet, on ⌃⌥H.
///
/// Rendered from the same command table that registers the hotkeys, so it cannot
/// disagree with the build: excluding a plugin removes its keys *and* its rows,
/// and rebinding a key changes both at once. A hand-written sheet is wrong the
/// first time anyone edits a binding.
@MainActor
final class HelpWindowController {

    private var window: NSWindow?
    private let commands: () -> [PluginCommand]
    private let scripts: () -> [CommandScript]

    init(commands: @escaping () -> [PluginCommand],
         scripts: @escaping () -> [CommandScript]) {
        self.commands = commands
        self.scripts = scripts
    }

    /// Toggle rather than show: the same chord that summons a cheat sheet should
    /// dismiss it, since that is usually the next thing you want.
    func toggle() {
        if let window, window.isVisible {
            window.orderOut(nil)
            return
        }
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Spaceman Shortcuts"
        window.contentView = NSHostingView(
            rootView: HelpView(commands: commands(), scripts: scripts())
        )
        window.contentMinSize = CGSize(width: 520, height: 360)
        // Come to the user rather than dragging the user to the window.
        // Without this, activating a window that was left on another Space
        // switches Spaces to reach it — which is exactly what a summoned panel
        // must not do. `.moveToActiveSpace` brings it here instead.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        return window
    }
}

private struct HelpView: View {
    let commands: [PluginCommand]
    let scripts: [CommandScript]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // Group order comes from the enum's declaration order, so it is
                // a typed choice rather than a string that has to match.
                ForEach(CommandGroup.allCases, id: \.self) { group in
                    let rows = commands.filter { $0.group == group && !$0.desc.isEmpty }
                    if !rows.isEmpty {
                        section(group.title) {
                            ForEach(rows, id: \.id) { command in
                                row(ChordGlyphs.string(keyCode: command.keyCode,
                                                       modifiers: command.modifiers),
                                    command.desc)
                            }
                        }
                    }
                }

                if !scripts.isEmpty {
                    section("Custom Commands") {
                        ForEach(scripts, id: \.name) { script in
                            row("spaceman://run/\(script.name)",
                                script.commands.map(\.describedName).joined(separator: " → "),
                                monospacedChord: true)
                        }
                    }
                }
            }
            .padding(20)
        }
        .frame(minWidth: 520, minHeight: 360)
    }

    private func section(_ title: String,
                         @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            content()
        }
    }

    /// The chord column is fixed width so every description starts at the same
    /// x — the point of a cheat sheet is scanning it, not reading it.
    private func row(_ chord: String, _ description: String,
                     monospacedChord: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(chord)
                .font(.system(size: monospacedChord ? 10 : 12,
                              weight: .medium,
                              design: .monospaced))
                .frame(width: 150, alignment: .leading)
                .foregroundStyle(.secondary)
            Text(description)
            Spacer()
        }
    }
}
