import Foundation

/// A launcher is where people already type, so an arithmetic query should answer
/// itself rather than sending them to a calculator app. This is a small
/// recursive-descent evaluator over a deliberately narrow grammar: numbers,
/// + - * / % ^, parentheses, and unary minus.
///
/// It is intentionally not a general expression language — no variables, no
/// function calls, no shelling out to anything. The whole input space is
/// arithmetic on literals, which keeps it safe by construction.
///
/// Ported from the Go version's `internal/plugins/launcher/calc.go`.
enum CalcEngine {

    enum CalcError: Error, Equatable {
        case unexpectedEnd
        case unexpected(String)
        case missingCloseParen
        case badNumber(String)
        case divisionByZero
        case moduloByZero
        case notFinite
    }

    /// Evaluates an arithmetic expression.
    static func eval(_ expression: String) throws -> Double {
        var parser = Parser(src: Array(expression.trimmingCharacters(in: .whitespaces)))
        let value = try parser.expr()
        parser.skipSpace()
        guard parser.pos == parser.src.count else {
            throw CalcError.unexpected(String(parser.src[parser.pos...]))
        }
        guard value.isFinite else { throw CalcError.notFinite }
        return value
    }

    /// Renders a result without a trailing ".0000000001" or an exponent for
    /// ordinary values.
    static func format(_ v: Double) -> String {
        if v == v.rounded() && abs(v) < 1e15 {
            return String(format: "%.0f", v)
        }
        return String(format: "%.10g", v)
    }
}

private struct Parser {
    let src: [Character]
    var pos = 0

    mutating func skipSpace() {
        while pos < src.count && src[pos].isWhitespace { pos += 1 }
    }

    mutating func peek() -> Character? {
        skipSpace()
        return pos < src.count ? src[pos] : nil
    }

    /// + and -, the lowest precedence.
    mutating func expr() throws -> Double {
        var v = try term()
        while let c = peek(), c == "+" || c == "-" {
            pos += 1
            let rhs = try term()
            v = c == "+" ? v + rhs : v - rhs
        }
        return v
    }

    /// * / and %.
    mutating func term() throws -> Double {
        var v = try power()
        while let c = peek(), c == "*" || c == "/" || c == "%" {
            pos += 1
            let rhs = try power()
            switch c {
            case "*": v *= rhs
            case "/":
                guard rhs != 0 else { throw CalcEngine.CalcError.divisionByZero }
                v /= rhs
            default:
                guard rhs != 0 else { throw CalcEngine.CalcError.moduloByZero }
                v = v.truncatingRemainder(dividingBy: rhs)
            }
        }
        return v
    }

    /// ^, which binds tighter than * and is right-associative.
    mutating func power() throws -> Double {
        let base = try unary()
        if peek() == "^" {
            pos += 1
            let exp = try power() // right-associative: 2^3^2 == 2^9
            return Foundation.pow(base, exp)
        }
        return base
    }

    mutating func unary() throws -> Double {
        if let c = peek(), c == "-" || c == "+" {
            pos += 1
            let v = try unary()
            return c == "-" ? -v : v
        }
        return try atom()
    }

    mutating func atom() throws -> Double {
        guard let c = peek() else { throw CalcEngine.CalcError.unexpectedEnd }
        if c == "(" {
            pos += 1
            let v = try expr()
            guard peek() == ")" else { throw CalcEngine.CalcError.missingCloseParen }
            pos += 1
            return v
        }
        let start = pos
        while pos < src.count
                && (src[pos].isNumber || src[pos] == "." || src[pos] == "_" || src[pos] == ",") {
            pos += 1
        }
        guard start < pos else { throw CalcEngine.CalcError.unexpected(String(c)) }
        // Thousands separators are convenience for typing, not part of the number.
        let literal = String(src[start..<pos])
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let v = Double(literal) else { throw CalcEngine.CalcError.badNumber(literal) }
        return v
    }
}
