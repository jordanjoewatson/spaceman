import Testing
import Foundation
@testable import ClipboardPlugin

@Suite("Clipboard store")
struct ClipboardStoreTests {

    @MainActor
    @Test("items and pins survive a reload from the same defaults")
    func persistenceRoundTrip() {
        let suite = "com.spaceman.tests.clipboard.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not open a defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ClipboardStore(defaults: defaults)
        first.add("keep")
        first.togglePin("keep")
        first.add("temp")

        let reloaded = ClipboardStore(defaults: defaults)
        #expect(reloaded.items.map(\.text) == ["temp", "keep"])
        #expect(reloaded.items.first(where: { $0.text == "keep" })?.pinned == true)
    }

    @MainActor
    @Test("capacity is stored and applied on the next load")
    func capacityPersists() {
        let suite = "com.spaceman.tests.clipboard.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            Issue.record("could not open a defaults suite")
            return
        }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = ClipboardStore(defaults: defaults)
        first.capacity = 3
        first.add("a")
        first.add("b")
        first.add("c")
        first.add("d")

        let reloaded = ClipboardStore(defaults: defaults)
        #expect(reloaded.capacity == 3)
        #expect(reloaded.items.map(\.text) == ["d", "c", "b"])
    }
}

@Suite("Clipboard capture rules")
struct ClipboardCaptureTests {

    @Test("plain text is accepted")
    func acceptsPlainText() {
        #expect(ClipboardCapture.acceptedText(string: "hello", types: ["public.utf8-plain-text"])
                == "hello")
    }

    @Test("empty and missing strings are rejected")
    func rejectsEmpty() {
        #expect(ClipboardCapture.acceptedText(string: "", types: ["public.utf8-plain-text"]) == nil)
        #expect(ClipboardCapture.acceptedText(string: nil, types: ["public.utf8-plain-text"]) == nil)
    }

    @Test("concealed pasteboard types are skipped")
    func skipsSecretTypes() {
        #expect(ClipboardCapture.acceptedText(
            string: "password",
            types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]) == nil)
        #expect(ClipboardCapture.acceptedText(
            string: "temp",
            types: ["org.nspasteboard.TransientType"]) == "temp")
    }
}
