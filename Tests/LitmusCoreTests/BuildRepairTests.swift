import Foundation
import Testing

@testable import LitmusCore

/// Taking out the mutants a build rejected, on a real injected copy.
@Suite("Build repair")
struct BuildRepairTests {
    private static let source = """
    func f(_ a: Int, _ b: Int) -> Bool {
        let first = a < b
        let second = a == b
        return first && second
    }
    """

    /// An original with one file, and its injected working copy.
    private final class Injected {
        let project: URL
        let copy: URL
        let mutants: [Mutant]

        init(_ source: String) throws {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-repair-\(UUID().uuidString)")
            project = base.appendingPathComponent("Project")
            copy = base.appendingPathComponent("Copy")

            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try source.write(
                to: project.appendingPathComponent("Sample.swift"), atomically: true, encoding: .utf8
            )
            mutants = try ProjectInjection()(project: project, workingCopy: copy).mutants
        }

        deinit {
            try? FileManager.default.removeItem(at: project.deletingLastPathComponent())
        }

        var file: String { copy.appendingPathComponent("Sample.swift").path }
        var text: String { (try? String(contentsOfFile: file, encoding: .utf8)) ?? "" }

        func lineNumber(containing mutant: Mutant) -> Int {
            let flag = MutationSwitch.flagName(mutant.switchName)
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            return (lines.firstIndex { $0.contains(flag) && !$0.contains("private var") } ?? 0) + 1
        }

        /// One repair for the life of the copy, as a run has.
        lazy var repairer = BuildRepair(project: project, workingCopy: copy)

        func repair(_ log: String) throws -> BuildRepair.Outcome {
            try repairer(log: log, mutants: mutants)
        }
    }

    /// A call takes numbers, `Comparable` and `Equatable`; a copy of the
    /// expression takes whatever the original did. Only a copy that fails
    /// too means the mutant itself does not build.
    @Test("moves an operator the compiler rejected back to a copy, and takes it out if that fails too")
    func namedLine() throws {
        let injected = try Injected(Self.source)
        let rejected = try #require(injected.mutants.first { $0.description.contains("<") })
        let flag = MutationSwitch.flagName(rejected.switchName)

        let first = try injected.repair(
            "\(injected.file):\(injected.lineNumber(containing: rejected)):20: error: cannot convert value"
        )

        #expect(first.removed.isEmpty)
        #expect(first.moved == 1)
        #expect(injected.text.contains("(\(flag) ? (a >= b) : (a < b))"))
        for kept in injected.mutants {
            #expect(injected.text.contains(MutationSwitch.flagName(kept.switchName)))
        }

        let second = try injected.repair(
            "\(injected.file):\(injected.lineNumber(containing: rejected)):20: error: binary operator '>=' cannot be applied"
        )

        #expect(second.removed == [rejected])
        #expect(second.moved == 0)
        #expect(!injected.text.contains(flag))
    }

    @Test("finds the call an error points into when the flag is on another line")
    func multilineCall() throws {
        let file = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-call-\(UUID().uuidString).swift")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        let x = __litmus_add(__litmus_outer, a, __litmus_mul(__litmus_inner, b,
            c.value))
        let y = 1
        """.write(to: file, atomically: true, encoding: .utf8)

        #expect(BuildRepair.enclosingCallFlag(at: (file.path, 2, 7), in: file.path) == "__litmus_inner")
        #expect(BuildRepair.enclosingCallFlag(at: (file.path, 3, 9), in: file.path) == nil)
    }

    @Test("takes out the whole file when the line has no switch on it")
    func unnamedLine() throws {
        let injected = try Injected(Self.source)

        let first = try injected.repair("\(injected.file):1:1: error: something further down broke")
        let second = try injected.repair("\(injected.file):1:1: error: something further down broke")

        // Operators go back to copies first; what is left goes the second time.
        #expect(first.moved == 3)
        #expect(Set((first.removed + second.removed).map(\.switchName)) == Set(injected.mutants.map(\.switchName)))
        #expect(injected.text == Self.source)
    }

    @Test("leaves everything alone when the error is in a file litmus did not write")
    func foreignFile() throws {
        let injected = try Injected(Self.source)
        let before = injected.text

        let outcome = try injected.repair("/elsewhere/Other.swift:3:1: error: no such module 'Lottie'")

        #expect(outcome.changedNothing)
        #expect(injected.text == before)
    }

    @Test("reads only error lines from a build log")
    func parsesErrors() {
        let log = """
        /p/A.swift:12:5: error: cannot find 'x' in scope
        /p/B.swift:3:1: warning: unused
        note: something
        /p/C.swift:7:9: error: type mismatch
        """

        #expect(BuildRepair.errors(in: log).map(\.path) == ["/p/A.swift", "/p/C.swift"])
        #expect(BuildRepair.errors(in: log).map(\.line) == [12, 7])
    }

    @Test("reads an error line swift build coloured")
    func coloured() {
        let log = "/p/A.swift:10:75: \u{1B}[1;31merror: \u{1B}[1;39mrequires Comparable\u{1B}[0;0m"

        #expect(BuildRepair.errors(in: log).map(\.line) == [10])
    }
}
