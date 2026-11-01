import Carbon.HIToolbox
import Foundation
import PluginKit
import SwiftUI

/// Lounge: a fullscreen, game-controller-driven home screen for the living
/// room.
///
/// The controller's home button (PS / Xbox / Guide) toggles it. The library is
/// whatever the user added — nothing is discovered or added automatically —
/// stored as versioned JSON in the plugin's data directory (`LoungeLibrary`).
///
/// **Security rule:** launch types are a closed enum (`LoungeLaunch`) filled
/// in through pickers and validated fields. There are no free-text commands
/// and no shell, ever. Process-backed launch types planned for later phases
/// (Docker Compose, Docker image) will use `Process` with a fixed executable
/// and argument array built only from validated values.
///
/// All controller code (and the GameController framework) lives in this
/// target, so a build without Lounge links none of it.
public enum LoungePlugin: SpacemanPlugin {

    public static let name = "lounge"
    public static let displayName = "Lounge"
    public static let summary = "A fullscreen home screen for games and apps, "
        + "driven by a game controller. Press the controller's home button to open it."

    enum Key {
        static let chord = "plugin.lounge.homeChord"
    }

    @MainActor
    public static func setup(host: any PluginHost) -> PluginInstance {
        UserDefaults.standard.register(defaults: [Key.chord: true])
        let store = LoungeStore(directory: host.dataDirectory(for: name))
        let lounge = LoungeController(store: store, host: host)
        let gamepad = LoungeGamepad { lounge.handle($0) }
        var chordObserver: NSObjectProtocol?

        return PluginInstance(
            commands: [
                PluginCommand(
                    id: "lounge.toggle",
                    keyCode: UInt32(kVK_ANSI_G),
                    modifiers: UInt32(controlKey | optionKey),
                    group: .apps,
                    desc: "Toggle Lounge",
                    action: { lounge.toggle() }
                ),
            ],
            scenes: [
                PluginScene(id: LoungeController.sceneID, title: "Lounge", style: .fullscreen) {
                    LoungeRootView(lounge: lounge, store: store, gamepad: gamepad)
                },
            ],
            settings: PluginSettings {
                LoungeSettingsPane(store: store,
                                   removed: { lounge.libraryRemoved($0) },
                                   added: { entry in
                                       if let id = entry.bundleID { host.setTilingExempt(bundleID: id, true) }
                                   })
            },
            start: {
                gamepad.chordEnabled = UserDefaults.standard.bool(forKey: Key.chord)
                chordObserver = NotificationCenter.default.addObserver(
                    forName: UserDefaults.didChangeNotification, object: nil, queue: .main
                ) { _ in
                    MainActor.assumeIsolated {
                        gamepad.chordEnabled = UserDefaults.standard.bool(forKey: Key.chord)
                    }
                }
                lounge.start()
                gamepad.start()
            },
            stop: {
                chordObserver.map(NotificationCenter.default.removeObserver)
                gamepad.stop()
                lounge.stop()
            }
        )
    }
}
