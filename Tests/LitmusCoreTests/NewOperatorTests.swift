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
        // Each operator a call, in the order the operators bind.
        #expect(result.source.contains("__litmus_add(__litmus_Sample_ChangeArithmeticOperator_2_15_"))
        #expect(result.source.contains("__litmus_rem(__litmus_Sample_ChangeArithmeticOperator_2_23_"))
        #expect(result.source.contains("__litmus_mul(__litmus_Sample_ChangeArithmeticOperator_2_19_"))
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
        // Written once, not once as it is and once behind `!`.
        #expect(result.source.contains("if __litmus_not(__litmus_Sample_NegateCondition_"))
        #expect(result.source.components(separatedBy: "items.contains(3)").count == 2)
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

    // MARK: - return values

    @Test("returns the empty value of the declared type")
    func returnValues() {
        let result = inject("""
        struct S {
            func enabled(_ a: Int) -> Bool { return a > 0 }
            func count(_ a: [Int]) -> Int { return a.count }
            func ratio(_ a: Double) -> Double { return a / 2 }
            func name(_ a: String) -> String { return a.uppercased() }
            func items(_ a: [Int]) -> [Int] { return a.filter { $0 > 0 } }
            func table(_ a: [String: Int]) -> [String: Int] { return a }
            func first(_ a: [Int]) -> Int? { return a.first }
            var total: Int { return 3 + 4 }
            subscript(i: Int) -> String { return String(i) }
        }
        """, ["ReplaceReturnValue"])

        #expect(result.mutants.map(\.description) == [
            "returned false instead", "returned 0 instead", "returned 0 instead", "returned \"\" instead",
            "returned [] instead", "returned [:] instead", "returned nil instead", "returned 0 instead",
            "returned \"\" instead",
        ])
        #expect(result.source.contains("? (nil) : (a.first))"))
        #expect(result.source.contains("? ([:]) : (a))"))
        #expect(isValidSwift(result.source))
    }

    /// A closure's return type is the compiler's to work out; a guess that
    /// does not match is a mutant that does not build.
    @Test("leaves a return alone where the type is unknown or the value is already empty")
    func returnValuesSkipped() {
        let result = inject("""
        struct S {
            func a(_ list: [Int]) -> [Int] { list.map { x in return x * 2 } }
            func b() -> Int? { return nil }
            func c() -> Bool { return false }
            func d() -> [Int] { return [] }
            func e() -> Int { return 0 }
            func f() -> some Collection { return [1] }
            func g() { return }
            func h() -> Widget { return Widget() }
            init?(x: Int) { return nil }
            func j(_ x: Int) -> String {
                return switch x { case 0: "zero" default: "other" }
            }
            func k(_ x: Bool) -> Int {
                return if x { 1 } else { 2 }
            }
            var i: Int {
                get { return 1 }
                set { return }
            }
        }
        """, ["ReplaceReturnValue"])

        #expect(result.mutants.map(\.description) == ["returned 0 instead"])
        #expect(isValidSwift(result.source))
    }

    @Test("keeps try and await inside the switched value")
    func returnValuesEffects() {
        let result = inject("""
        func load() async throws -> String {
            return try await fetch()
        }
        """, ["ReplaceReturnValue"])

        #expect(result.source.contains("? (\"\") : (try await fetch()))"))
        #expect(isValidSwift(result.source))
    }
}
