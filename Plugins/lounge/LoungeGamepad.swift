import Foundation
import GameController
import os

let loungeLog = Logger(subsystem: "Spaceman", category: "lounge")

/// What Lounge does with a controller, independent of which controller it is.
enum LoungeInput: Equatable {
    case up, down, left, right
    /// South face button (✕ / A).
    case confirm
    /// East face button (◯ / B).
    case back
    /// West face button (◻ / X): secondary action, e.g. Quit.
    case secondary
    /// L2 / R2 (LT / RT): page zoom in Lounge's web view.
    case zoomOut, zoomIn
    /// South held for `holdDuration`: remove the focused tile.
    case hold
    case previousSpace, nextSpace
    /// PS / Xbox / Guide, or the fallback chord.
    case home
}

/// The SF Symbol names of the connected controller's own buttons, for the hint
/// bar. Read from each element's `sfSymbolsName` so a DualSense shows ✕ ◯ and
/// an Xbox pad shows A B. Fallbacks are generic shapes, never one vendor's.
struct LoungeGlyphs: Equatable {
    var confirm = "circle.circle"
    var back = "circle.circle"
    var secondary = "circle.circle"
    var previous = "arrowtriangle.left.circle"
    var next = "arrowtriangle.right.circle"
    var home = "house.circle"
    var dpad = "dpad"
}

/// Owns every `GCController` interaction. The rest of the plugin only sees
/// `LoungeInput` and `LoungeGlyphs`.
@MainActor
final class LoungeGamepad: ObservableObject {

    @Published private(set) var glyphs = LoungeGlyphs()
    @Published private(set) var controllerName: String?

    /// Whether Options+Share / Menu+View also counts as Home. A fallback for
    /// controllers (or macOS versions) where the home button can't be claimed.
    var chordEnabled = true

    private let onInput: (LoungeInput) -> Void
    private var observers: [NSObjectProtocol] = []
    /// Per-controller stick state, so a held stick moves focus once per push
    /// rather than once per frame.
    private var stickLatched: [ObjectIdentifier: Bool] = [:]
    /// Pending "held long enough" timers for the South button, per controller.
    private var holdTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    static let holdDuration: TimeInterval = 0.8
    /// Raw-HID fallback for the home button, which macOS otherwise swallows.
    private var hidHome: LoungeHIDHome?
    /// The same press can arrive from GameController and from raw HID.
    private var lastHome = Date.distantPast

    init(onInput: @escaping (LoungeInput) -> Void) {
        self.onInput = onInput
    }

    func start() {
        // Spaceman is an agent app and Lounge must hear the home button while a
        // game is frontmost.
        GCController.shouldMonitorBackgroundEvents = true
        loungeLog.info("gamepad monitor started, \(GCController.controllers().count) controller(s)")
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.configure(controller) }
        })
        observers.append(center.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] note in
            guard let controller = note.object as? GCController else { return }
            MainActor.assumeIsolated { self?.disconnected(controller) }
        })
        GCController.controllers().forEach(configure)
        GCController.startWirelessControllerDiscovery {}
        let hid = LoungeHIDHome { [weak self] in
            MainActor.assumeIsolated { self?.home() }
        }
        hid.start()
        hidHome = hid
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        GCController.stopWirelessControllerDiscovery()
        hidHome?.stop()
        hidHome = nil
    }

    private func home() {
        guard Date().timeIntervalSince(lastHome) > 0.3 else { return }
        lastHome = Date()
        onInput(.home)
    }

    private func disconnected(_ controller: GCController) {
        stickLatched[ObjectIdentifier(controller)] = nil
        if let next = GCController.current ?? GCController.controllers().first {
            refreshGlyphs(for: next)
        } else {
            controllerName = nil
            glyphs = LoungeGlyphs()
        }
    }

    private func configure(_ controller: GCController) {
        loungeLog.info("controller connected: \(controller.vendorName ?? "?", privacy: .public) extended=\(controller.extendedGamepad != nil) home=\(controller.extendedGamepad?.buttonHome != nil)")
        guard let pad = controller.extendedGamepad else { return }
        controller.handlerQueue = .main
        let key = ObjectIdentifier(controller)

        let emit: (LoungeInput) -> Void = { [weak self] input in
            loungeLog.debug("input: \(String(describing: input), privacy: .public)")
            MainActor.assumeIsolated {
                self?.refreshGlyphs(for: controller)
                if input == .home { self?.home() } else { self?.onInput(input) }
            }
        }
        func onPress(_ button: GCControllerButtonInput?, _ input: LoungeInput) {
            button?.pressedChangedHandler = { _, _, pressed in if pressed { emit(input) } }
        }

        // South acts on release, so holding it can mean "remove" instead.
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            MainActor.assumeIsolated {
                guard let self else { return }
                if pressed {
                    let timer = DispatchWorkItem { [weak self] in
                        self?.holdTimers[key] = nil
                        emit(.hold)
                    }
                    self.holdTimers[key] = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + Self.holdDuration, execute: timer)
                } else if let timer = self.holdTimers.removeValue(forKey: key) {
                    timer.cancel()
                    emit(.confirm)
                }
            }
        }
        onPress(pad.buttonB, .back)
        onPress(pad.buttonX, .secondary)
        onPress(pad.leftTrigger, .zoomOut)
        onPress(pad.rightTrigger, .zoomIn)
        onPress(pad.leftShoulder, .previousSpace)
        onPress(pad.rightShoulder, .nextSpace)
        onPress(pad.dpad.up, .up)
        onPress(pad.dpad.down, .down)
        onPress(pad.dpad.left, .left)
        onPress(pad.dpad.right, .right)

        // Claim the home button from the system (otherwise macOS opens
        // Launchpad / Game Center on it).
        if let home = pad.buttonHome {
            home.preferredSystemGestureState = .disabled
            onPress(home, .home)
        }

        // Fallback chord: Options+Share (PlayStation) / Menu+View (Xbox).
        let chord: GCControllerButtonValueChangedHandler = { [weak self] _, _, pressed in
            guard pressed, pad.buttonMenu.isPressed, pad.buttonOptions?.isPressed == true else { return }
            MainActor.assumeIsolated {
                guard self?.chordEnabled == true else { return }
                emit(.home)
            }
        }
        pad.buttonMenu.pressedChangedHandler = chord
        pad.buttonOptions?.pressedChangedHandler = chord

        pad.leftThumbstick.valueChangedHandler = { [weak self] _, x, y in
            MainActor.assumeIsolated {
                guard let self else { return }
                let magnitude = max(abs(x), abs(y))
                if magnitude < 0.3 { self.stickLatched[key] = false; return }
                guard magnitude > 0.6, self.stickLatched[key] != true else { return }
                self.stickLatched[key] = true
                if abs(x) > abs(y) { emit(x > 0 ? .right : .left) } else { emit(y > 0 ? .up : .down) }
            }
        }

        refreshGlyphs(for: controller)
    }

    private func refreshGlyphs(for controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        var g = LoungeGlyphs()
        if let s = pad.buttonA.sfSymbolsName { g.confirm = s }
        if let s = pad.buttonB.sfSymbolsName { g.back = s }
        if let s = pad.buttonX.sfSymbolsName { g.secondary = s }
        if let s = pad.leftShoulder.sfSymbolsName { g.previous = s }
        if let s = pad.rightShoulder.sfSymbolsName { g.next = s }
        if let s = pad.buttonHome?.sfSymbolsName { g.home = s }
        if let s = pad.dpad.sfSymbolsName { g.dpad = s }
        if g != glyphs { glyphs = g }
        if controllerName != controller.vendorName { controllerName = controller.vendorName }
    }
}
