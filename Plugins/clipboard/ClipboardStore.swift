import Foundation

/// Persistent FIFO, stored in `UserDefaults` under `plugin.clipboard.`.
///
/// The list is user content, but it is small (text, capped, N ≤ 100) and this
/// app already keeps configuration in prefs — one plist, `defaults read`, no
/// extra file.
@MainActor
final class ClipboardStore: ObservableObject {

    enum Key {
        static let size = "plugin.clipboard.size"
        static let items = "plugin.clipboard.items"
    }

    private let defaults: UserDefaults
    private var history: ClipboardHistory

    @Published private(set) var items: [ClipboardItem] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.size: ClipboardHistory.defaultCapacity,
            Key.items: "[]",
        ])
        let loaded = Self.loadItems(from: defaults)
        history = ClipboardHistory(items: loaded,
                                   capacity: defaults.integer(forKey: Key.size))
        items = history.items
        // A smaller capacity than last save may have evicted entries; write
        // that back so reload matches what the bar is showing.
        if history.items != loaded { persist() }
    }

    var capacity: Int {
        get { history.capacity }
        set {
            history.setCapacity(newValue)
            defaults.set(history.capacity, forKey: Key.size)
            publish()
        }
    }

    func add(_ text: String) {
        let before = history
        history.add(text)
        guard history != before else { return }
        publish()
    }

    func togglePin(_ text: String) {
        let before = history
        history.togglePin(text)
        guard history != before else { return }
        publish()
    }

    private func publish() {
        items = history.items
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(history.items),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Key.items)
    }

    private static func loadItems(from defaults: UserDefaults) -> [ClipboardItem] {
        guard let json = defaults.string(forKey: Key.items),
              let data = json.data(using: .utf8),
              let items = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return [] }
        return items
    }
}
