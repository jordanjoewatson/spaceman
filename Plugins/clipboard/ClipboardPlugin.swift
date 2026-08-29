import Carbon.HIToolbox
import SwiftUI
import PluginKit

/// A FIFO of snippets captured with ⌃⌥C, shown as bar chips.
///
/// Native ⌘C is never intercepted. Capture synthesizes a real copy in the
/// focused app, then stores the resulting string. Clicking a chip writes that
/// snippet back to the pasteboard so ⌘V pastes it.
public enum ClipboardPlugin: SpacemanPlugin {

    public static let name = "clipboard"
    public static let displayName = "Clipboard"
    public static let summary = "A history of snippets you capture with ⌃⌥C, "
        + "shown in the bar. Click one to copy it back."

    @MainActor
    public static func setup(host: any PluginHost) -> PluginInstance {
        let store = ClipboardStore()

        return PluginInstance(
            commands: [
                PluginCommand(
                    id: "clipboard.capture",
                    keyCode: UInt32(kVK_ANSI_C),
                    modifiers: UInt32(controlKey | optionKey),
                    group: .apps,
                    desc: "Capture selection to clipboard history",
                    action: {
                        ClipboardCapture.capture(into: store) { host.note($0) }
                    }
                ),
            ],
            barModules: [
                PluginBarModule(id: "clipboard.history",
                                title: "Clipboard",
                                summary: "Saved snippets — click to copy, star to pin") {
                    ClipboardBarModule(store: store, palette: host.palette) {
                        host.note("Copied")
                    }
                },
            ],
            settings: PluginSettings {
                ClipboardSettingsPane(store: store)
            }
        )
    }
}
