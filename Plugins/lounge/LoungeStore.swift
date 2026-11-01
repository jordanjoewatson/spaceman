import AppKit
import Foundation

/// The user's library, persisted to `library.json` in the plugin's data
/// directory. Nothing appears here unless the user adds it.
@MainActor
final class LoungeStore: ObservableObject {

    @Published private(set) var entries: [LoungeEntry] = []

    private let fileURL: URL
    /// False when the file exists but couldn't be read (corrupt, or written by
    /// a newer version): saving then would destroy it, so edits stay in memory.
    private var writable = true

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("library.json")
        if let data = try? Data(contentsOf: fileURL) {
            if let library = LoungeLibrary.decode(data) {
                entries = library.entries
            } else {
                writable = false
            }
        }
    }

    @discardableResult
    func add(_ entry: LoungeEntry) -> Bool {
        guard (try? LoungeValidation.validate(entry)) != nil else { return false }
        if let id = entry.bundleID, entries.contains(where: { $0.bundleID == id }) { return false }
        entries.append(entry)
        save()
        return true
    }

    func addApp(at url: URL) -> Bool {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return false }
        return add(LoungeEntry(title: LoungeApps.displayName(of: url),
                               launch: .app(bundleID: id, path: url.path)))
    }

    func update(_ entry: LoungeEntry) {
        guard (try? LoungeValidation.validate(entry)) != nil,
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index] = entry
        save()
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        entries.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func contains(bundleID: String) -> Bool {
        entries.contains { $0.bundleID == bundleID }
    }

    private func save() {
        guard writable, let data = try? LoungeLibrary(entries: entries).encoded() else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// Installed apps, for pickers and the Suggested row. Read-only: nothing here
/// ever adds to the library by itself.
enum LoungeApps {

    struct Installed: Identifiable, Hashable {
        let url: URL
        let bundleID: String
        let name: String
        let isGame: Bool
        var id: String { bundleID }
    }

    static func scan() -> [Installed] {
        let fm = FileManager.default
        let roots = [URL(fileURLWithPath: "/Applications"),
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        var seen = Set<String>()
        var result: [Installed] = []
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { continue }
            // One level of folders too (e.g. /Applications/Games/…).
            let apps = items.flatMap { url -> [URL] in
                if url.pathExtension == "app" { return [url] }
                return ((try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.pathExtension == "app" }
            }
            for url in apps {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                      seen.insert(id).inserted else { continue }
                let category = bundle.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String
                result.append(Installed(url: url, bundleID: id, name: displayName(of: url),
                                        isGame: isGameCategory(category)))
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// `public.app-category.games` and its sub-genres
    /// (`public.app-category.action-games`, …).
    static func isGameCategory(_ category: String?) -> Bool {
        guard let category = category?.lowercased(),
              category.hasPrefix("public.app-category.") else { return false }
        return category.hasSuffix("games")
    }

    static func displayName(of url: URL) -> String {
        FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
    }

    static func url(for entry: LoungeEntry) -> URL? {
        guard case let .app(bundleID, path) = entry.launch else { return nil }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return url }
        if let path, FileManager.default.fileExists(atPath: path) { return URL(fileURLWithPath: path) }
        return nil
    }

    static func icon(for entry: LoungeEntry) -> NSImage? {
        url(for: entry).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }
}
