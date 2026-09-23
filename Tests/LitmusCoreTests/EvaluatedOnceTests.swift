import Foundation
import Testing

@testable import LitmusCore

/// Values Swift computes once per process keep whichever mutant was on when
/// they were first read, so a batch has to leave them out.
@Suite("Evaluated once")
struct EvaluatedOnceTests {
    private func flags(_ source: String) -> [Bool] {
        SchemataInjector().inject(source: source, path: "/tmp/Sample.swift").mutants.map(\.evaluatedOnce)
    }

    @Test("a global's initial value")
    func global() {
        #expect(flags("let limit = 1 > 2") == [true])
    }

    @Test("a static property's initial value")
    func staticProperty() {
        #expect(flags("""
        enum Config {
            static let enabled = 1 > 2
        }
        """) == [true])
    }

    @Test("a class property's initial value")
    func classProperty() {
        #expect(flags("""
        final class Config {
            class var enabled: Bool { get { 1 > 2 } }
            static var other = 1 > 2
        }
        """) == [false, true])
    }

    @Test("the body of a closure run once to build a static value")
    func immediatelyRunClosure() {
        let found = flags("""
        enum Config {
            static let value: Int = {
                let base = 1 > 2 ? 3 : 4
                return base
            }()
        }
        """)

        #expect(found.count == 2)
        #expect(found.allSatisfy { $0 })
    }

    @Test("not an instance property, which each instance computes again")
    func instanceProperty() {
        #expect(flags("""
        struct Config {
            let enabled = 1 > 2
        }
        """) == [false])
    }

    @Test("not a computed static property, which runs on every read")
    func computedStatic() {
        #expect(flags("""
        enum Config {
            static var enabled: Bool { 1 > 2 }
        }
        """) == [false])
    }

    @Test("not a static function")
    func staticFunction() {
        #expect(flags("""
        enum Config {
            static func enabled() -> Bool {
                let value = 1 > 2
                return value
            }
        }
        """) == [false])
    }

    @Test("not a function declared at file scope")
    func globalFunction() {
        #expect(flags("""
        func enabled() -> Bool {
            let value = 1 > 2
            return value
        }
        """) == [false])
    }

    @Test("survives a plan written and read back")
    func planRoundTrip() throws {
        let mutant = Mutant(
            filePath: "/p/A.swift", line: 1, column: 1, utf8Offset: 0,
            operator: "RelationalOperatorReplacement", description: "d",
            evaluatedOnce: true
        )
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("litmus-plan-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try Plan.write([mutant], workingCopy: URL(fileURLWithPath: "/p"), to: url)

        #expect(try Plan.read(contentsOf: url).map(\.evaluatedOnce) == [true])
    }
}
