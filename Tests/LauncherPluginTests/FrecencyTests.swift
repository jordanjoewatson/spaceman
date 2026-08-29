import Foundation
import Testing
@testable import LauncherPlugin

@Suite("Frecency")
struct FrecencyTests {

    private func tempPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("spaceman-test-\(UUID().uuidString).json")
    }

    private func result(_ title: String) -> LauncherResult {
        LauncherResult(title: title, subtitle: "") {}
    }

    // Ranking is "lower is better", so usage subtracts. A frequently chosen
    // result should win a tie, without a never-used result becoming unreachable.
    @MainActor
    @Test("frecency biases ranking without burying")
    func biasesRanking() {
        let frecency = Frecency(path: tempPath())
        let results = [result("Notes"), result("Numbers")]

        // With no history, fuzzy order stands.
        #expect(ranked("n", results, limit: 8, uses: frecency).first?.title == "Notes")

        for _ in 0..<5 { frecency.record("Numbers") }
        #expect(ranked("n", results, limit: 8, uses: frecency).first?.title == "Numbers")

        // A precise query still finds the never-used one.
        #expect(ranked("notes", results, limit: 8, uses: frecency).first?.title == "Notes")
    }

    // Scores decay so that habits which change are followed rather than
    // remembered forever.
    @Test("score decays with age")
    func decays() {
        let frecency = Frecency(path: tempPath())
        frecency.record("Old")
        let fresh = frecency.score("Old")

        // Backdate the record by four half-lives.
        frecency.uses["Old"]?.seen = Date(timeIntervalSinceNow: -4 * Frecency.halfLife)

        #expect(frecency.score("Old") < fresh)
    }

    @Test("usage history round-trips through disk")
    func roundTrips() {
        let path = tempPath()
        let frecency = Frecency(path: path)
        frecency.record("Safari")
        frecency.record("Safari")

        let again = Frecency(path: path)
        #expect(again.score("Safari") == frecency.score("Safari"))
        #expect(again.score("Never") == 0)
    }

    // A missing or corrupt file means "no history", never a startup failure.
    @Test("tolerates a missing file")
    func toleratesBadFile() {
        let frecency = Frecency(path: tempPath())
        #expect(frecency.score("x") == 0)
    }
}
