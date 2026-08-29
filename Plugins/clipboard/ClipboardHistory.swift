import Foundation

/// One saved snippet. `text` is unique in the history — capturing the same
/// string again moves it to the front rather than duplicating it.
struct ClipboardItem: Codable, Equatable, Sendable, Identifiable {
    var text: String
    var pinned: Bool

    var id: String { text }
}

/// Fixed-capacity FIFO of clipboard entries. Newest is first.
///
/// When full, the oldest unpinned entry is evicted. Pinned entries stay until
/// unpinned. If every slot is pinned, a new capture is dropped rather than
/// pushing a kept snippet out.
struct ClipboardHistory: Equatable, Sendable {
    /// UTF-8 byte cap per snippet. UserDefaults holds the whole list in the
    /// app's prefs plist; one huge paste must not bloat it.
    static let maxTextBytes = 16 * 1024
    static let minCapacity = 1
    static let maxCapacity = 100
    static let defaultCapacity = 10
    /// How a chip and a tooltip read a snippet — one line, short.
    static let previewLimit = 24

    private(set) var items: [ClipboardItem]
    private(set) var capacity: Int

    init(items: [ClipboardItem] = [], capacity: Int = defaultCapacity) {
        self.items = items
        self.capacity = Self.clampedCapacity(capacity)
        evictToCapacity()
    }

    static func clampedCapacity(_ value: Int) -> Int {
        min(max(value, minCapacity), maxCapacity)
    }

    /// Truncate to `maxTextBytes` on a character boundary.
    static func clipped(_ text: String) -> String {
        if text.utf8.count <= maxTextBytes { return text }
        var result = ""
        result.reserveCapacity(maxTextBytes)
        var bytes = 0
        for character in text {
            let extra = String(character).utf8.count
            if bytes + extra > maxTextBytes { break }
            result.append(character)
            bytes += extra
        }
        return result
    }

    /// Flatten whitespace and truncate for a chip label.
    static func preview(_ text: String) -> String {
        let flat = text.map { character -> Character in
            if character.isNewline || character == "\t" { return " " }
            return character
        }
        let trimmed = String(flat)
        if trimmed.count <= previewLimit { return trimmed }
        return String(trimmed.prefix(previewLimit - 1)) + "…"
    }

    mutating func setCapacity(_ value: Int) {
        capacity = Self.clampedCapacity(value)
        evictToCapacity()
    }

    /// Insert at the front. Empty strings are ignored. An existing match is
    /// moved to the front and keeps its pin.
    mutating func add(_ text: String) {
        let text = Self.clipped(text)
        guard !text.isEmpty else { return }

        if let index = items.firstIndex(where: { $0.text == text }) {
            let existing = items.remove(at: index)
            items.insert(existing, at: 0)
            return
        }

        evictForNewEntry()
        guard items.count < capacity else { return }
        items.insert(ClipboardItem(text: text, pinned: false), at: 0)
    }

    mutating func togglePin(_ text: String) {
        guard let index = items.firstIndex(where: { $0.text == text }) else { return }
        items[index].pinned.toggle()
    }

    /// Drop the oldest unpinned item. If every item is pinned, leave the list
    /// as-is so `add` can refuse the new entry.
    private mutating func evictForNewEntry() {
        guard items.count >= capacity else { return }
        if let evict = items.lastIndex(where: { !$0.pinned }) {
            items.remove(at: evict)
        }
    }

    /// After a capacity shrink, evict oldest-unpinned first. If the list is
    /// still over (everything left is pinned), keep the newest `capacity`.
    private mutating func evictToCapacity() {
        while items.count > capacity {
            if let evict = items.lastIndex(where: { !$0.pinned }) {
                items.remove(at: evict)
            } else {
                items = Array(items.prefix(capacity))
                return
            }
        }
    }
}
