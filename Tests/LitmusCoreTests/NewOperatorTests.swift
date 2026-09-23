import SwiftParser
import Testing

@testable import LitmusCore

@Suite("Arithmetic, boolean and condition operators")
struct NewOperatorTests {
    private func inject(_ source: String, _ operators: [String]) -> SchemataInjector.Result {
        SchemataInjector(operators: operators).inject(source: source, path: "/tmp/Sample.swift")
    }

    private func isValidSwift(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    // MARK: - arithmetic

    @Test("swaps arithmetic operators within their precedence group")
    func arithmetic() {
        let result = inject("""
        func f(_ a: Int, _ b: Int) -> Int {
            let x = a + b * 2 % 3
            return x - 1 / b
        }
        """, ["ChangeArithmeticOperator"])

        #expect(Set(result.mutants.map(\.description)) == [
            "changed + to -", "changed * to /", "changed % to *", "changed - to +", "changed / to *",
        ])
        #expect(result.source.contains("a - b * 2 % 3"))
        #expect(isValidSwift(result.source))
    }

    @Test("leaves + alone beside a string or array literal")
    func notConcatenation() {
        let result = inject("""
        func f(_ name: String, _ list: [Int]) -> String {
            let joined = list + [1]
            return "Hello, " + name
        }
        """, ["ChangeArithmeticOperator"])

        #expect(result.mutants.isEmpty)
    }

    // MARK: - boolean literals

    @Test("flips a boolean literal")
    func boolean() {
        let result = inject("""
        func f() -> Bool {
            let enabled = true
            return enabled
        }
        """, ["FlipBooleanLiteral"])

        #expect(result.mutants.map(\.description) == ["changed true to false"])
        #expect(result.source.contains("? (false) : (true)"))
        #expect(isValidSwift(result.source))
    }

    @Test("leaves literals the compiler reads alone")
    func compileTimeLiterals() {
        let result = inject("""
        #if true
        let a = 1
        #endif
        enum E: Bool { case on = true }
        @available(*, deprecated)
        func f(_ x: Bool = false) -> Int {
            switch x {
            case true: return 1
            default: return 0
            }
        }
        """, ["FlipBooleanLiteral"])

        #expect(result.mutants.isEmpty)
    }

    // MARK: - conditions

    @Test("negates the condition of if, guard and while")
    func conditions() {
        let result = inject("""
        func f(_ items: [Int]) -> Int {
            guard !items.isEmpty else { return 0 }
            var i = 0
            while i < items.count { i = i + 1 }
            if items.contains(3) { return 3 }
            return i
        }
        """, ["NegateCondition"])

        #expect(result.mutants.count == 3)
        #expect(result.mutants.allSatisfy { $0.description == "negated the condition" })
        #expect(result.source.contains("? (!(items.contains(3))) : (items.contains(3))"))
        #expect(isValidSwift(result.source))
    }

    @Test("leaves optional binding and pattern conditions alone")
    func bindings() {
        let result = inject("""
        func f(_ x: Int?) -> Int {
            if let x { return x }
            if case .some(let y) = x { return y }
            return 0
        }
        """, ["NegateCondition"])

        #expect(result.mutants.isEmpty)
    }

    @Test("stacks on a condition another operator also changed")
    func stacked() {
        let result = inject("""
        func f(_ a: Int, _ b: Int) -> Bool {
            if a < b { return true }
            return false
        }
        """, ["RelationalOperatorReplacement", "NegateCondition", "FlipBooleanLiteral"])

        #expect(result.mutants.count == 4)
        #expect(isValidSwift(result.source))
    }
}
