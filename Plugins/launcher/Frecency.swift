import Foundation

/// Ranking purely by fuzzy score means the launcher never learns: the app you
/// open twenty times a day sits behind an alphabetically luckier one forever.
/// Frecency fixes that by folding in how often and how recently a result was
/// chosen.
///
/// The score decays with a half-life rather than counting raw hits, so habits
/// that change are followed rather than remembered forever.
///
/// Ported from the Go version's `internal/plugins/launcher/frecency.go`.
final class Frecency {

    struct UseRecord: Codable {
        var score: Double
        var seen: Date
    }

    /// How long it takes a single use to count for half as much.
    static let halfLife: TimeInterval = 14 * 24 * 60 * 60

    /// How strongly usage may outrank text-match quality. Fuzzy scores are
    /// "lower is better", and a strong substring match scores near zero, so
    /// this is deliberately modest: frequent choices win ties and near-ties,
    /// but a precise query still finds a never-used result.
    static let weight: Double = 300

    let path: URL

    /// Internal (not private) so tests can backdate records, as the Go tests do.
    var uses: [String: UseRecord] = [:]
    private var dirty = false

    /// Where the usage record lives by default: alongside commands.json.
    static var defaultPath: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first!
        return base.appendingPathComponent("Spaceman/launcher-uses.json")
    }

    /// Reads the usage record; a missing or unreadable file simply means "no
    /// history yet", never an error the user has to care about.
    init(path: URL) {
        self.path = path
        guard let data = try? Data(contentsOf: path) else { return }
        do {
            uses = try JSONDecoder().decode([String: UseRecord].self, from: data)
        } catch {
            NSLog("launcher: unreadable usage history %@: %@", path.path, error.localizedDescription)
        }
    }

    /// A record's score as of `now`.
    static func decayed(_ r: UseRecord, at now: Date) -> Double {
        let age = now.timeIntervalSince(r.seen)
        guard age > 0 else { return r.score }
        return r.score * pow(0.5, age / halfLife)
    }

    /// The frecency bonus for a title: 0 for something never chosen, rising
    /// towards `weight` the more often and recently it was.
    func score(_ title: String) -> Int {
        guard let r = uses[title] else { return 0 }
        let s = Self.decayed(r, at: Date())
        // Saturating curve: the tenth use matters far less than the second, so
        // one heavily-used entry can't dominate everything forever.
        return Int(Self.weight * s / (s + 3))
    }

    /// Notes that a result was chosen.
    func record(_ title: String) {
        guard !title.isEmpty else { return }
        let now = Date()
        var r = uses[title] ?? UseRecord(score: 0, seen: now)
        r.score = Self.decayed(r, at: now) + 1
        r.seen = now
        uses[title] = r
        dirty = true
        prune()
        save()
    }

    /// Drops entries that have decayed into irrelevance, so the file can't grow
    /// without bound as apps come and go.
    private func prune() {
        let now = Date()
        uses = uses.filter { Self.decayed($0.value, at: now) >= 0.05 }
    }

    /// Persists the record. Failures are logged, not surfaced: losing launcher
    /// history is a minor annoyance, not something to interrupt the user for.
    func save() {
        guard dirty else { return }
        do {
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(uses)
            try data.write(to: path, options: .atomic)
            dirty = false
        } catch {
            NSLog("launcher: saving usage history: %@", error.localizedDescription)
        }
    }
}
