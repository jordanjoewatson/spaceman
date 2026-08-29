import AppKit
import Carbon.HIToolbox

/// Global hotkeys via `RegisterEventHotKey`.
///
/// Unlike `CGEventTap` this needs no Input Monitoring consent and cannot
/// observe keystrokes it did not register for — and it fires even while another
/// app is full-screen, which is when a tiler's shortcuts matter most.
@MainActor
final class HotkeyManager {

    struct Shortcut {
        let keyCode: UInt32
        let modifiers: UInt32
        let handler: () -> Void
    }

    private var registered: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?
    private var nextID: UInt32 = 1

    /// Carbon dispatches to a C function pointer with no context of its own, so
    /// the live instance is parked here for the trampoline to find.
    ///
    /// `nonisolated(unsafe)` because `deinit` is not main-actor isolated. Every
    /// read and write happens on the main thread — Carbon delivers hot-key
    /// events there, and the app never constructs this type anywhere else — so
    /// the unchecked access is accurate rather than a suppression.
    private nonisolated(unsafe) static var active: HotkeyManager?

    init() {
        HotkeyManager.active = self
        installHandler()
    }

    deinit {
        // Carbon refs must be released explicitly.
        for ref in registered.values { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        if HotkeyManager.active === self { HotkeyManager.active = nil }
    }

    private func installHandler() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, event, _ -> OSStatus in
                guard let event else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
                )
                guard status == noErr else { return status }

                // Carbon calls us on the main thread; hop explicitly so the
                // compiler is satisfied and the contract is documented.
                DispatchQueue.main.async {
                    HotkeyManager.active?.handlers[hotKeyID.id]?()
                }
                return noErr
            },
            1, &spec, nil, &eventHandler
        )
    }

    /// Register one shortcut. Returns false if the combination is already taken
    /// by another app — a normal outcome that must not be fatal.
    @discardableResult
    func register(keyCode: UInt32, modifiers: UInt32, handler: @escaping () -> Void) -> Bool {
        let id = nextID
        nextID += 1

        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x53504D4E) /* 'SPMN' */, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID,
                                         GetEventDispatcherTarget(), 0, &ref)

        guard status == noErr, let ref else { return false }
        registered[id] = ref
        handlers[id] = handler
        return true
    }
}

/// Virtual key codes we bind. Named so the call sites read as the actual keys.
enum KeyCode {
    static let space: UInt32 = 49
    static let t: UInt32 = 17
    static let minus: UInt32 = 27
    static let equal: UInt32 = 24
    static let one: UInt32 = 18
    static let two: UInt32 = 19
    static let three: UInt32 = 20
    static let four: UInt32 = 21
    static let five: UInt32 = 23
    static let six: UInt32 = 22
    static let zero: UInt32 = 29
    static let f: UInt32 = 3
    static let m: UInt32 = 46
    static let d: UInt32 = 2
    static let h: UInt32 = 4
    static let o: UInt32 = 31
    static let r: UInt32 = 15
    static let c: UInt32 = 8
    static let p: UInt32 = 35
    static let s: UInt32 = 1
    static let leftArrow: UInt32 = 123
    static let rightArrow: UInt32 = 124
    static let downArrow: UInt32 = 125
    static let upArrow: UInt32 = 126
}

enum Modifiers {
    static let controlOption = UInt32(controlKey | optionKey)
    static let controlOptionCommand = UInt32(controlKey | optionKey | cmdKey)
    static let controlOptionShift = UInt32(controlKey | optionKey | shiftKey)
}
