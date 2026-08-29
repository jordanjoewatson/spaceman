/// The shared fuzzy matcher, ported from the Go version's `internal/ui/match`.
/// It lives in PluginKit rather than inside any one plugin because several need
/// it: the launcher ranks apps and commands with it, and a window finder ranks
/// windows. Keeping it here is what lets those plugins be included or excluded
/// independently.
public enum FuzzyMatch {

    /// Reports whether `query` subsequence-matches `target` (case-insensitive)
    /// and a score where lower is better (fewer/tighter gaps). Empty query
    /// matches everything with score 0. Returns nil on no match.
    public static func score(_ query: String, _ target: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query.lowercased())
        let t = Array(target.lowercased())

        // Strong bonus for a direct substring match, ranked by position.
        let tString = String(t), qString = String(q)
        if let range = tString.range(of: qString) {
            return tString.distance(from: tString.startIndex, to: range.lowerBound)
        }

        // Acronym match on word initials ("vsc" -> "Visual Studio Code"), which
        // ranks between substring and loose subsequence matches.
        if q.count > 1 {
            var initials: [Character] = []
            var prevSep = true
            for c in t {
                let sep = c == " " || c == "-" || c == "_" || c == "."
                if !sep && prevSep { initials.append(c) }
                prevSep = sep
            }
            if initials.count >= q.count, Array(initials.prefix(q.count)) == q {
                return 500
            }
        }

        // Otherwise subsequence match with a gap penalty.
        var score = 0, ti = 0, last = -1
        for qc in q {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    if last >= 0 { score += ti - last }
                    last = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        return score + 1000 // subsequence ranks below substring matches
    }

    /// Convenience predicate form of `score`.
    public static func matches(_ query: String, _ target: String) -> Bool {
        score(query, target) != nil
    }
}
