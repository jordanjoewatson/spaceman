import Testing
@testable import PluginKit

@Suite("FuzzyMatch")
struct FuzzyMatchTests {

    @Test("empty query matches everything with the best score")
    func emptyQuery() {
        #expect(FuzzyMatch.score("", "Safari") == 0)
    }

    @Test("substring matches case-insensitively, scored by position")
    func substring() {
        #expect(FuzzyMatch.score("saf", "Safari") == 0)
        #expect(FuzzyMatch.score("far", "Safari") == 2)
        #expect(FuzzyMatch.score("SAF", "Safari") == 0)
    }

    @Test("acronym match on word initials")
    func acronym() {
        #expect(FuzzyMatch.score("vsc", "Visual Studio Code") == 500)
    }

    @Test("subsequence match carries a gap penalty and ranks below substring")
    func subsequence() {
        let score = FuzzyMatch.score("abc", "aXbXc")
        #expect(score != nil)
        #expect(score! >= 1000)
    }

    @Test("no match returns nil")
    func noMatch() {
        #expect(FuzzyMatch.score("xyz", "Safari") == nil)
        #expect(FuzzyMatch.score("notes", "Numbers") == nil)
    }

    @Test("match kinds rank substring < acronym < subsequence")
    func rankingOrder() {
        let query = "vc"
        let substring = FuzzyMatch.score(query, "avcd")!       // "vc" at index 1
        let acronym = FuzzyMatch.score(query, "Visual Code")!
        // "vac": no substring, no acronym ("c" is not a word start) — subsequence.
        let subsequence = FuzzyMatch.score(query, "vac")!
        #expect(substring < acronym)
        #expect(acronym < subsequence)
    }
}
