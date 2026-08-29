import Carbon.HIToolbox
import PluginKit

/// Interactive window swapping on ⌃⌥S.
///
/// Contributes only a command — no window, no bar module, no settings. That is
/// the point of the contract's optional fields: a plugin declares what it has,
/// and this one has a mode.
public enum SwapPlugin: SpacemanPlugin {

    public static let name = "swap"
    public static let displayName = "Swap"
    public static let summary = "Trade two tiled windows' positions: arrows pick "
        + "the target, Return swaps."

    @MainActor
    public static func setup(host: any PluginHost) -> PluginInstance {
        let mode = SwapMode(host: host)

        return PluginInstance(
            commands: [
                PluginCommand(
                    id: "swap.toggle",
                    keyCode: UInt32(kVK_ANSI_S),
                    modifiers: UInt32(controlKey | optionKey),
                    group: .windows,
                    desc: "Swap windows (arrows pick, Return trades)",
                    action: { mode.toggle() }
                ),
            ],
            // Rings are windows; leaving them up through a shutdown would strand
            // borderless panels on screen.
            stop: { mode.cancel() }
        )
    }
}
