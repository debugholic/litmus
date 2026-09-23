import SwiftParser
import Testing

@testable import LitmusCore

@Suite("Ternaries that pick text")
struct StringTernaryTests {
    private func mutants(_ source: String) -> [Mutant] {
        SchemataInjector(operators: ["SwapTernary"]).inject(source: source, path: "/tmp/Sample.swift").mutants
    }

    @Test("leaves a ternary between two strings alone")
    func label() {
        #expect(mutants("""
        func title(_ game: Bool, _ name: String) -> String {
            let plain = game ? "Quiz" : "Review"
            return game ? "Hello, \\(name)" : "Bye"
        }
        """).isEmpty)
    }

    @Test("still swaps a ternary with anything else in a branch")
    func logic() {
        #expect(mutants("""
        func pick(_ flag: Bool, _ a: Int, _ label: String) -> String {
            let n = flag ? a : 0
            return flag ? label : "none"
        }
        """).count == 2)
    }
}
