import Testing
@testable import LauncherPlugin

@Suite("CalcEngine")
struct CalcEngineTests {

    @Test("evaluates arithmetic", arguments: [
        ("1+1", 2.0),
        ("2*3+4", 10.0),
        ("4+2*3", 10.0),    // precedence
        ("(4+2)*3", 18.0),  // parentheses
        ("10/4", 2.5),
        ("7%3", 1.0),
        ("2^10", 1024.0),
        ("2^3^2", 512.0),   // right-associative: 2^(3^2)
        ("-5+2", -3.0),     // unary minus
        ("-(3*2)", -6.0),
        ("1_000+1", 1001.0), // separators are typing convenience
        ("1,500*2", 3000.0),
        (" 3 * 4 ", 12.0),  // whitespace
    ])
    func eval(expr: String, want: Double) throws {
        let got = try CalcEngine.eval(expr)
        #expect(abs(got - want) < 1e-9)
    }

    // The grammar is deliberately narrow — literals and operators only.
    // Anything else must be rejected rather than guessed at.
    @Test("rejects non-arithmetic", arguments: [
        "", "1+", "*3", "(1+2", "1+2)", "abc", "1/0", "7%0",
        "1 2", "$(whoami)", "1;2", "os.Exit(1)",
    ])
    func rejects(expr: String) {
        #expect(throws: CalcEngine.CalcError.self) { try CalcEngine.eval(expr) }
    }

    // A search that merely contains a digit or a dash must not be hijacked
    // into a calculator result.
    @MainActor
    @Test("calc provider only answers arithmetic", arguments: [
        "", "safari", "42", "notes", "visual studio code",
    ])
    func providerIgnoresSearches(query: String) {
        #expect(CalcProvider().query(query).isEmpty)
    }

    @MainActor
    @Test("calc provider answers a sum")
    func providerAnswers() {
        let results = CalcProvider().query("12*12")
        #expect(results.count == 1)
        #expect(results[0].title == "144")
    }

    @Test("format drops the decimal point for integers")
    func format() {
        #expect(CalcEngine.format(144) == "144")
        #expect(CalcEngine.format(2.5) == "2.5")
    }
}
