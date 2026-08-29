import Testing
@testable import ClipboardPlugin

@Suite("Clipboard history")
struct ClipboardHistoryTests {

    @Test("newest is first and the oldest unpinned is evicted")
    func fifoEviction() {
        var history = ClipboardHistory(capacity: 3)
        history.add("a")
        history.add("b")
        history.add("c")
        history.add("d")
        #expect(history.items.map(\.text) == ["d", "c", "b"])
    }

    @Test("a pin protects that entry and the next eviction skips it")
    func pinnedNotEvicted() {
        var history = ClipboardHistory(capacity: 3)
        history.add("a")
        history.add("b")
        history.add("c")
        history.togglePin("a")
        history.add("d")
        let texts = history.items.map(\.text)
        #expect(texts.contains("a"))
        #expect(!texts.contains("b"))
        #expect(texts.contains("d"))
    }

    @Test("when every slot is pinned a new capture is dropped")
    func allPinnedDropsNew() {
        var history = ClipboardHistory(capacity: 2)
        history.add("a")
        history.add("b")
        history.togglePin("a")
        history.togglePin("b")
        history.add("c")
        #expect(history.items.map(\.text) == ["b", "a"])
    }

    @Test("re-capturing a string moves it to the front and keeps its pin")
    func dedupMovesToFront() {
        var history = ClipboardHistory(capacity: 5)
        history.add("a")
        history.add("b")
        history.togglePin("a")
        history.add("a")
        #expect(history.items.map(\.text) == ["a", "b"])
        #expect(history.items[0].pinned)
    }

    @Test("empty strings are ignored")
    func emptyIgnored() {
        var history = ClipboardHistory()
        history.add("")
        #expect(history.items.isEmpty)
    }

    @Test("a huge paste is truncated rather than stored whole")
    func clipsLongText() {
        let huge = String(repeating: "x", count: ClipboardHistory.maxTextBytes + 50)
        var history = ClipboardHistory()
        history.add(huge)
        #expect(history.items.count == 1)
        #expect(history.items[0].text.utf8.count <= ClipboardHistory.maxTextBytes)
        #expect(history.items[0].text.utf8.count == ClipboardHistory.maxTextBytes)
    }

    @Test("shrinking capacity evicts oldest unpinned first")
    func shrinkEvictsUnpinned() {
        var history = ClipboardHistory(capacity: 4)
        history.add("a")
        history.add("b")
        history.add("c")
        history.add("d")
        history.togglePin("a")
        history.setCapacity(2)
        let texts = history.items.map(\.text)
        #expect(texts.contains("a"), "pinned oldest is kept")
        #expect(texts.contains("d"), "newest is kept")
        #expect(texts.count == 2)
    }

    @Test("absurd capacities are clamped")
    func clampsCapacity() {
        #expect(ClipboardHistory.clampedCapacity(0) == 1)
        #expect(ClipboardHistory.clampedCapacity(9999) == 100)
        let history = ClipboardHistory(capacity: 0)
        #expect(history.capacity == 1)
    }

    @Test("preview flattens whitespace and truncates")
    func preview() {
        #expect(ClipboardHistory.preview("hello") == "hello")
        #expect(ClipboardHistory.preview("a\nb\tc") == "a b c")
        let long = String(repeating: "x", count: 40)
        let preview = ClipboardHistory.preview(long)
        #expect(preview.hasSuffix("…"))
        #expect(preview.count == ClipboardHistory.previewLimit)
    }
}
