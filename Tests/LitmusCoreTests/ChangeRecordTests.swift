import Testing

@testable import LitmusCore

/// What each mutant records about its change, for the report.
@Suite("Change record")
struct ChangeRecordTests {
    private func mutants(_ source: String) -> [Mutant] {
        SchemataInjector().inject(source: source, path: "/tmp/Sample.swift").mutants
    }

    @Test("names the function and type a mutant sits in")
    func function() throws {
        let mutant = try #require(mutants("""
        final class GameResult {
            func handleRowTap(for result: Int, _ other: Int) {
                let same = result == other
                print(same)
            }
        }
        """).first { $0.operator == "RelationalOperatorReplacement" })

        #expect(mutant.change?.function == "GameResult.handleRowTap(for:_:)")
    }

    @Test("names a property, an initializer and an extension's type")
    func otherDeclarations() {
        let found = mutants("""
        struct Box {
            var isEmpty: Bool { count == 0 }
            let count: Int
            init(count: Int) { self.count = count > 0 ? count : 0 }
        }
        extension Box {
            func twice() -> Int { count * 2 }
        }
        """).compactMap(\.change?.function)

        #expect(Set(found) == ["Box.isEmpty", "Box.init(count:)", "Box.twice()"])
    }

    @Test("shows the whole expression before and after an operator swap")
    func operatorChange() throws {
        let mutant = try #require(mutants("""
        func f(_ a: Int, _ b: Int) -> Bool {
            return a < b
        }
        """).first)
        let change = try #require(mutant.change)

        #expect(change.original == "a < b")
        #expect(change.replacement == "a >= b")
        #expect(change.startLine == 2)
        #expect(change.startColumn == 12)
        #expect(change.endColumn == 17)
    }

    @Test("says which call was removed, with its argument labels")
    func removedCall() {
        let found = mutants("""
        func f(_ list: inout [Int], actions: Actions?) {
            list.insert(1, at: 0)
            actions?.showDetail(3)
        }
        """).filter { $0.operator == "RemoveSideEffects" }.map(\.description)

        #expect(found == ["removed the call to insert(_:at:)", "removed the call to showDetail(_:)"])
    }

    @Test("shows a negated condition and a flipped literal")
    func conditionAndLiteral() {
        let changes = mutants("""
        func f(_ items: [Int]) -> Bool {
            if items.isEmpty { return true }
            return false
        }
        """).compactMap(\.change).map { "\($0.original) → \($0.replacement)" }

        #expect(changes.contains("items.isEmpty → !(items.isEmpty)"))
        #expect(changes.contains("true → false"))
    }
}
