import AppKit
import ApplicationServices
import CoreGraphics

/// How a capture is taken from the focused app, and what is allowed in.
///
/// Native ⌘C is never observed. Capture prefers the focused field's selected
/// text (Accessibility), then a synthetic ⌘C once ⌃⌥ are no longer held —
/// posting copy on the key-down of ⌃⌥C is ignored by most apps because those
/// modifiers are still down.
enum ClipboardCapture {

    /// Only skip pasteboard entries that are marked as secrets. Transient and
    /// auto-generated flags are used too loosely by some apps to treat as a ban.
    static let skipTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
    ]

    static func acceptedText(string: String?, types: Set<String>) -> String? {
        if types.contains(where: { raw in skipTypes.contains(NSPasteboard.PasteboardType(raw)) }) {
            return nil
        }
        guard let string, !string.isEmpty else { return nil }
        return ClipboardHistory.clipped(string)
    }

    /// Copy the focused app's current selection into the history and the
    /// system pasteboard.
    @MainActor
    static func capture(into store: ClipboardStore, note: @escaping (String) -> Void) {
        if let text = selectedText(), let accepted = acceptedText(string: text, types: []) {
            writeToPasteboard(accepted)
            store.add(accepted)
            note("Copied")
            return
        }

        Task { @MainActor in
            await waitForLeaderRelease()
            let pasteboard = NSPasteboard.general
            let before = pasteboard.changeCount
            postCommandC()

            for _ in 0..<40 {
                try? await Task.sleep(for: .milliseconds(25))
                if pasteboard.changeCount != before { break }
            }

            guard pasteboard.changeCount != before else {
                note("Nothing to copy")
                return
            }

            let types = Set((pasteboard.types ?? []).map(\.rawValue))
            guard let text = acceptedText(string: pasteboard.string(forType: .string),
                                          types: types) else {
                note("Nothing to copy")
                return
            }
            store.add(text)
            note("Copied")
        }
    }

    static func writeToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Selected text in the focused field or window. Works for most AppKit,
    /// TextEdit, browsers; terminals and some Electron apps return nothing.
    private static func selectedText() -> String? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier else { return nil }

        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)

        if let focused = copyElement(app, kAXFocusedUIElementAttribute),
           let text = stringAttribute(focused, kAXSelectedTextAttribute),
           !text.isEmpty {
            return text
        }
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            if let window = copyElement(app, attribute),
               let text = stringAttribute(window, kAXSelectedTextAttribute),
               !text.isEmpty {
                return text
            }
        }
        return nil
    }

    private static func copyElement(_ element: AXUIElement, _ name: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success,
              let value else { return nil }
        return (value as! AXUIElement)
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    /// ⌃⌥ are still down when the hotkey fires. Wait until they are not, so
    /// the synthetic copy is a plain ⌘C.
    private static func waitForLeaderRelease() async {
        for _ in 0..<25 {
            let flags = NSEvent.modifierFlags
            if !flags.contains(.control) && !flags.contains(.option) { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Keycode 8 is `c`. A private event source so the physically-held
    /// modifiers are not mixed into the posted event.
    private static func postCommandC() {
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        if let pid, pid != ProcessInfo.processInfo.processIdentifier {
            down?.postToPid(pid)
            up?.postToPid(pid)
        } else {
            down?.post(tap: .cghidEventTap)
            up?.post(tap: .cghidEventTap)
        }
    }
}
