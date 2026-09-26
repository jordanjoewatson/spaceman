import AppKit
import Carbon.HIToolbox
import PluginKit

/// Every keyboard command this build has: the core's own, then whatever the
/// loaded plugins contribute.
///
/// One table, in `PluginCommand` form, rather than a tuple array for the core
/// and a typed list for plugins. That is what lets the help sheet be *derived*
/// from the bindings instead of maintained beside them — a cheat sheet written
/// by hand disagrees with the build the first time anyone edits a key, which is
/// exactly the failure the Go version avoided the same way.
@MainActor
enum CommandCatalog {

    /// The core's bindings. Built against the tiler, so it must be alive.
    static func core(tiler: TilingController) -> [PluginCommand] {
        func command(_ id: String, _ key: UInt32, _ group: CommandGroup, _ desc: String,
                     modifiers: UInt32 = Modifiers.controlOption,
                     _ action: @escaping @MainActor () -> Void) -> PluginCommand {
            PluginCommand(id: id, keyCode: key, modifiers: modifiers,
                          group: group, desc: desc, action: action)
        }

        return [
            command("focus.left", KeyCode.leftArrow, .focus, "Focus left")
                { [weak tiler] in tiler?.focus(.left) },
            command("focus.right", KeyCode.rightArrow, .focus, "Focus right")
                { [weak tiler] in tiler?.focus(.right) },
            command("focus.up", KeyCode.upArrow, .focus, "Focus up")
                { [weak tiler] in tiler?.focus(.up) },
            command("focus.down", KeyCode.downArrow, .focus, "Focus down")
                { [weak tiler] in tiler?.focus(.down) },
            command("display.warp", KeyCode.d, .focus, "Move pointer to next display")
                { [weak tiler] in tiler?.warpPointerToNextDisplay() },

            command("window.zoom", KeyCode.f, .windows, "Zoom / unzoom window")
                { [weak tiler] in tiler?.toggleZoom() },
            command("window.minimize", KeyCode.m, .windows, "Minimize window")
                { [weak tiler] in tiler?.minimizeFocused() },

            command("window.narrower", KeyCode.leftArrow, .windows,
                    "Narrower", modifiers: Modifiers.controlOptionShift)
                { [weak tiler] in tiler?.resize(.left) },
            command("window.wider", KeyCode.rightArrow, .windows,
                    "Wider", modifiers: Modifiers.controlOptionShift)
                { [weak tiler] in tiler?.resize(.right) },
            command("window.taller", KeyCode.upArrow, .windows,
                    "Taller", modifiers: Modifiers.controlOptionShift)
                { [weak tiler] in tiler?.resize(.up) },
            command("window.shorter", KeyCode.downArrow, .windows,
                    "Shorter", modifiers: Modifiers.controlOptionShift)
                { [weak tiler] in tiler?.resize(.down) },
            command("window.sizes.reset", KeyCode.zero, .windows, "Reset window sizes")
                { [weak tiler] in tiler?.resetSizes() },

            command("layout.cycle", KeyCode.space, .layout, "Cycle layout")
                { [weak tiler] in tiler?.cycleLayout() },
            command("layout.retile", KeyCode.r, .layout, "Re-tile")
                { [weak tiler] in tiler?.tileNow() },
            command("layout.master.shrink", KeyCode.minus, .layout, "Shrink master")
                { [weak tiler] in tiler?.adjustMaster(by: -0.05) },
            command("layout.master.grow", KeyCode.equal, .layout, "Grow master")
                { [weak tiler] in tiler?.adjustMaster(by: 0.05) },
            command("layout.grid", KeyCode.one, .layout, "Grid layout")
                { [weak tiler] in tiler?.setLayout(.spaceman) },
            command("layout.master", KeyCode.two, .layout, "Master layout")
                { [weak tiler] in tiler?.setLayout(.masterStack) },
            command("layout.bsp", KeyCode.three, .layout, "BSP layout")
                { [weak tiler] in tiler?.setLayout(.bsp) },
            command("layout.columns", KeyCode.four, .layout, "Columns layout")
                { [weak tiler] in tiler?.setLayout(.columns) },
            command("layout.rows", KeyCode.five, .layout, "Rows layout")
                { [weak tiler] in tiler?.setLayout(.rows) },
            command("layout.monocle", KeyCode.six, .layout, "Monocle layout")
                { [weak tiler] in tiler?.setLayout(.monocle) },
        ]
    }
}

/// A command's chord, written the way a Mac user reads it.
enum ChordGlyphs {

    static func string(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierGlyphs(modifiers) + keyGlyph(keyCode)
    }

    /// Apple's order: control, option, shift, command.
    static func modifierGlyphs(_ modifiers: UInt32) -> String {
        var glyphs = ""
        if modifiers & UInt32(controlKey) != 0 { glyphs += "⌃" }
        if modifiers & UInt32(optionKey)  != 0 { glyphs += "⌥" }
        if modifiers & UInt32(shiftKey)   != 0 { glyphs += "⇧" }
        if modifiers & UInt32(cmdKey)     != 0 { glyphs += "⌘" }
        return glyphs
    }

    /// ANSI letter/digit keycodes plus the few named keys we bind. A plugin
    /// that uses a letter we have not listed in `KeyCode` still shows the
    /// letter rather than `#35`.
    private static let lettersAndDigits: [UInt32: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7",
        28: "8", 25: "9", 29: "0",
    ]

    private static func keyGlyph(_ keyCode: UInt32) -> String {
        if let letter = lettersAndDigits[keyCode] { return letter }
        switch keyCode {
        case KeyCode.space:      return "Space"
        case KeyCode.minus:      return "−"
        case KeyCode.equal:      return "="
        case KeyCode.leftArrow:  return "←"
        case KeyCode.rightArrow: return "→"
        case KeyCode.upArrow:    return "↑"
        case KeyCode.downArrow:  return "↓"
        default:                 return "#\(keyCode)"
        }
    }
}
