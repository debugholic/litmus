import SwiftParser
import Testing

@testable import LitmusCore

@Suite("Schemata injection")
struct SchemataInjectorTests {
    private func inject(_ source: String, path: String = "/tmp/Sample.swift") -> SchemataInjector.Result {
        SchemataInjector().inject(source: source, path: path)
    }

    /// Anything Litmus writes has to compile, or every mutant in the file is
    /// reported as an error and the file contributes nothing.
    private func isValidSwift(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    @Test("finds a logical connector")
    func findsConnector() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) -> Bool {
            let value = a && b
            return value
        }
        """)

        #expect(result.mutants.count == 1)
        #expect(result.mutants[0].description == "changed && to ||")
        #expect(isValidSwift(result.source))
    }

    @Test("guards the mutation behind the environment")
    func wrapsInSwitch() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) -> Bool {
            return a && b
        }
        """)

        #expect(result.source.contains("getenv(\"LITMUS_ACTIVE\")"))
        #expect(result.source.contains(result.mutants[0].switchName))
        // The original has to survive as the else branch.
        #expect(result.source.contains("a && b"))
        #expect(result.source.contains("a || b"))
    }

    /// Muter drops mutations in blocks preceded by non-ASCII text, because it
    /// measures an edit in characters and applies it in UTF-8 bytes. Litmus
    /// rewrites through the syntax tree, so the comment cannot shift anything.
    @Test("is unaffected by non-ASCII comments before the mutation")
    func handlesNonASCII() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) -> Bool {
            // 같은 지점은 한 번만 담는다. 서버로 나가기 전에 끊어야 한다.
            let value = a && b
            return value
        }
        """)

        #expect(result.mutants.count == 1)
        #expect(result.source.contains("a || b"))
        #expect(isValidSwift(result.source))
    }

    @Test("puts several mutants in one file behind their own switches")
    func multipleMutants() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) -> Bool {
            // 첫 번째
            let first = a && b
            // 두 번째
            let second = a == b
            return first && second
        }
        """)

        #expect(result.mutants.count == 3)
        #expect(Set(result.mutants.map(\.switchName)).count == 3)
        #expect(isValidSwift(result.source))
    }

    @Test("leaves a file with nothing to mutate alone")
    func noMutants() {
        let source = """
        struct Empty {
            let value = 1
        }
        """
        let result = inject(source)

        #expect(result.mutants.isEmpty)
        #expect(result.source == source)
    }

    @Test("keeps a closure capture list intact")
    func preservesCaptureList() {
        // The shape that came out corrupted as `[wea!= elf]` when offsets drifted.
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) {
            // 한글 주석
            Task { [weak self] in
                let value = a && b
                print(value)
            }
        }
        """)

        #expect(result.source.contains("[weak self]"))
        #expect(isValidSwift(result.source))
    }
}

@Suite("Nested blocks")
struct NestedBlockTests {
    /// Restricted to token swaps: the point here is nesting, and the other
    /// operators would add mutants that have nothing to do with it.
    private func inject(_ source: String) -> SchemataInjector.Result {
        SchemataInjector(operators: TokenOperator.allCases.map(\.rawValue))
            .inject(source: source, path: "/tmp/Sample.swift")
    }

    private func isValidSwift(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    /// The shape that lost mutants before: one in the function body and one
    /// inside a closure nested in it. Wrapping the outer block used to stop the
    /// walk, so the inner mutant was dropped without a word.
    @Test("keeps a mutant inside a nested closure")
    func nestedClosure() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool, _ c: Bool) {
            let outer = a && b
            run {
                let inner = b && c
                print(inner)
            }
            print(outer)
        }
        """)

        #expect(result.mutants.count == 2)
        #expect(isValidSwift(result.source))
    }

    @Test("keeps a mutant inside a catch block")
    func nestedCatch() {
        let result = inject("""
        func f(_ a: String, _ b: String) async {
            let same = a == b
            do {
                try await work()
            } catch {
                guard a == b else { return }
                print(same)
            }
        }
        """)

        #expect(result.mutants.count == 2)
        #expect(isValidSwift(result.source))
    }

    @Test("gives every nested mutant its own switch")
    func separateSwitches() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) {
            let outer = a && b
            run {
                let inner = a && b
                print(inner)
            }
            print(outer)
        }
        """)

        let names = Set(result.mutants.map(\.switchName))
        #expect(names.count == 2)
        for name in names {
            #expect(result.source.contains(name))
        }
    }
}

@Suite("Structural operators")
struct StructuralOperatorTests {
    private func inject(_ source: String, operators: [String]? = nil) -> SchemataInjector.Result {
        SchemataInjector(operators: operators).inject(source: source, path: "/tmp/Sample.swift")
    }

    private func isValidSwift(_ source: String) -> Bool {
        !Parser.parse(source: source).hasError
    }

    @Test("swaps the branches of a ternary")
    func swapsTernary() {
        let result = inject("""
        func f(_ flag: Bool) -> Int {
            let value = flag ? 1 : 2
            return value
        }
        """, operators: ["SwapTernary"])

        #expect(result.mutants.count == 1)
        #expect(result.source.contains("flag ? 2 : 1"))
        #expect(result.source.contains("flag ? 1 : 2"))
        #expect(isValidSwift(result.source))
    }

    @Test("drops a call whose result is unused")
    func removesDiscardedCall() {
        let result = inject("""
        func f() {
            log("starting")
            work()
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.count == 2)
        #expect(isValidSwift(result.source))
    }

    /// A call whose value is used is not a side effect to drop — removing it
    /// would not compile, and the mutant would be an error rather than a signal.
    @Test("leaves a call whose value is used alone")
    func keepsUsedCall() {
        let result = inject("""
        func f() -> Int {
            let value = compute()
            return value
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.isEmpty)
    }

    /// An initializer has to reach its delegation on every path, so a guarded
    /// `super.init` does not compile. A mutant that fails to build teaches the
    /// suite nothing and still costs a run.
    @Test("leaves an initializer's delegation alone")
    func keepsInitializerDelegation() {
        let result = inject("""
        final class Bar: Foo {
            override init() {
                super.init()
                configure()
            }
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.count == 1)
        #expect(result.mutants[0].line == 4)
        #expect(isValidSwift(result.source))
    }

    /// `var x: T { call() }` is an implicit return: guarding the call would
    /// leave the getter with nothing to return.
    @Test("leaves a single-expression getter alone")
    func keepsImplicitReturn() {
        let result = inject("""
        struct Device {
            static var identifier: String? {
                lookUpIdentifier()
            }
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.isEmpty)
    }

    /// The same shape in a void function body is not a return, so the call is
    /// still fair game.
    @Test("drops the only call in a void function")
    func removesSoleCallInVoidFunction() {
        let result = inject("""
        func f() {
            notify()
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.count == 1)
        #expect(isValidSwift(result.source))
    }

    /// A statement that is nothing but an expression covers exactly the same
    /// bytes as the expression inside it. Keying sites by offsets alone put the
    /// expression's mutation on both, so a getter's only statement came out
    /// wrapped in an `if` and the getter returned nothing.
    @Test("does not mistake a statement for the expression filling it")
    func separatesStatementFromExpression() {
        let result = inject("""
        enum Connection {
            case none
            case wifi

            var isAvailable: Bool {
                self != .none
            }
        }
        """)

        #expect(result.mutants.count == 1)
        #expect(result.mutants[0].operator == "RelationalOperatorReplacement")
        #expect(!result.source.contains("if !__litmus"))
        #expect(isValidSwift(result.source))
    }

    /// An initializer whose body traps satisfies the compiler because it
    /// cannot finish. Behind a flag it can, and then it returns without having
    /// initialized anything.
    @Test("leaves a call that never returns alone")
    func keepsTrappingCall() {
        let result = inject("""
        final class Bar: Foo {
            required init?(coder: NSCoder) {
                fatalError("not supported")
            }
        }
        """, operators: ["RemoveSideEffects"])

        #expect(result.mutants.isEmpty)
    }

    @Test("runs every operator together")
    func allOperators() {
        let result = inject("""
        func f(_ a: Bool, _ b: Bool) -> Int {
            notify()
            let ok = a && b
            return ok ? 1 : 2
        }
        """)

        let operators = Set(result.mutants.map(\.operator))
        #expect(operators.contains("RemoveSideEffects"))
        #expect(operators.contains("ChangeLogicalConnector"))
        #expect(operators.contains("SwapTernary"))
        #expect(isValidSwift(result.source))
    }
}
