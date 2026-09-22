import SwiftParser
import Testing

@testable import LitmusCore

/// Which calls `RemoveSideEffects` may guard.
///
/// The rule is "a block whose only statement is an expression is an implicit
/// return", and the exceptions are the bodies that cannot stand in for a value.
/// Every one of those exceptions survived a mutation run: the suite only ever
/// exercised a function, a getter and an initializer's delegation, so the rest
/// of the list could have been anything.
@Suite("Removable calls")
struct RemovableCallTests {
    private func mutants(_ source: String) -> [Mutant] {
        SchemataInjector(operators: ["RemoveSideEffects"])
            .inject(source: source, path: "/tmp/Sample.swift")
            .mutants
    }

    private func isValidSwift(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    // MARK: - bodies that cannot be a value

    @Test("guards the only call in an initializer")
    func initializerBody() {
        #expect(mutants("""
        final class Bar {
            init() {
                configure()
            }
        }
        """).count == 1)
    }

    @Test("guards the only call in a deinitializer")
    func deinitializerBody() {
        #expect(mutants("""
        final class Bar {
            deinit {
                tearDown()
            }
        }
        """).count == 1)
    }

    @Test("guards the only call in a for body")
    func forBody() {
        #expect(mutants("""
        func f(_ items: [Int]) {
            for item in items {
                handle(item)
            }
        }
        """).count == 1)
    }

    @Test("guards the only call in a while body")
    func whileBody() {
        #expect(mutants("""
        func f() {
            while keepGoing() {
                step()
            }
        }
        """).count == 1)
    }

    @Test("guards the only call in a repeat body")
    func repeatBody() {
        #expect(mutants("""
        func f() {
            repeat {
                step()
            } while keepGoing()
        }
        """).count == 1)
    }

    @Test("guards the only call in a defer body")
    func deferBody() {
        #expect(mutants("""
        func f() {
            defer {
                cleanUp()
            }
            work()
        }
        """).count == 2)
    }

    /// A setter cannot be an implicit return; a getter is nothing else.
    @Test("guards a setter's only call but not a getter's")
    func accessorBodies() {
        let found = mutants("""
        struct Box {
            var value: Int {
                get { compute() }
                set { notify(newValue) }
            }
        }
        """)

        #expect(found.count == 1)
        #expect(found[0].line == 4)
    }

    // MARK: - bodies that can be a value

    @Test("leaves the only call in a closure alone")
    func closureBody() {
        // Litmus has no types here, so it cannot tell a void closure from one
        // whose single expression is its result.
        #expect(mutants("""
        func f() {
            let make = { compute() }
            use(make)
        }
        """).count == 1)
    }

    @Test("leaves the only call in a guard's else alone")
    func guardElse() {
        // Guarding it would let the body fall through, which does not compile.
        let source = """
        func f(_ value: Int?) {
            guard value != nil else { report() }
            work()
        }
        """

        #expect(mutants(source).count == 1)
        #expect(isValidSwift(
            SchemataInjector(operators: ["RemoveSideEffects"])
                .inject(source: source, path: "/tmp/Sample.swift").source
        ))
    }

    @Test("leaves the only call in a function that returns a value alone")
    func returningFunction() {
        #expect(mutants("""
        func f() -> Int {
            compute()
        }
        """).isEmpty)
    }

    // MARK: - operator selection

    /// The collector checks which operator it is running as. Without this, a
    /// run restricted to token swaps would still drop statements.
    @Test("finds nothing when another operator is selected")
    func respectsOperatorSelection() {
        let found = SchemataInjector(operators: ["ChangeLogicalConnector"])
            .inject(source: """
            func f(_ a: Bool, _ b: Bool) {
                notify()
                let ok = a && b
                use(ok)
            }
            """, path: "/tmp/Sample.swift")
            .mutants

        #expect(found.count == 1)
        #expect(found[0].operator == "ChangeLogicalConnector")
    }
}
