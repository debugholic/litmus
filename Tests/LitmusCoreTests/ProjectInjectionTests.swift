import Foundation
import Testing

@testable import LitmusCore

/// Copying a project and writing every mutant into the copy.
///
/// Built on a real directory in a temporary folder: the rules being checked are
/// about what is on disk, and a fake file system would only test the fake.
@Suite("Project injection")
struct ProjectInjectionTests {
    /// A tree written under a fresh temporary directory, removed afterwards.
    private final class Sandbox {
        let root: URL

        init(_ files: [String: String]) throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("litmus-tests-\(UUID().uuidString)")

            for (path, contents) in files {
                let file = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        func read(_ path: String) -> String? {
            try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
        }
    }

    private static let mutable = """
    func f(_ a: Bool, _ b: Bool) -> Bool {
        return a && b
    }
    """

    private func inject(
        _ files: [String: String],
        include: String? = nil
    ) throws -> (result: ProjectInjection.Result, copy: Sandbox) {
        let source = try Sandbox(files)
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-copy-\(UUID().uuidString)")

        let result = try ProjectInjection(include: include)(
            project: source.root,
            workingCopy: destination
        )

        // Wrapped so the copy is cleaned up with the same deinit.
        let copy = try Sandbox([:])
        try? FileManager.default.removeItem(at: copy.root)
        try FileManager.default.moveItem(at: destination, to: copy.root)

        return (result, copy)
    }

    // MARK: - what gets mutated

    @Test("writes the mutants into the copy and leaves the original alone")
    func leavesOriginalAlone() throws {
        let source = try Sandbox(["Sources/A.swift": Self.mutable])
        let destination = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("litmus-copy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: destination) }

        let result = try ProjectInjection()(project: source.root, workingCopy: destination)

        #expect(!result.mutants.isEmpty)
        #expect(source.read("Sources/A.swift") == Self.mutable)

        let copied = try String(
            contentsOf: destination.appendingPathComponent("Sources/A.swift"),
            encoding: .utf8
        )
        #expect(copied.contains("__litmus_"))
    }

    /// Test code is the thing being measured. Mutating it would let the suite
    /// grade itself.
    @Test("skips a Tests directory")
    func skipsTests() throws {
        let (result, copy) = try inject([
            "Sources/A.swift": Self.mutable,
            "Tests/ATests.swift": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { $0.filePath.contains("Sources") })
        #expect(copy.read("Tests/ATests.swift") == Self.mutable)
    }

    @Test("skips a Test directory too")
    func skipsSingularTest() throws {
        let (result, copy) = try inject([
            "Sources/A.swift": Self.mutable,
            "Test/ATests.swift": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { $0.filePath.contains("Sources") })
        #expect(copy.read("Test/ATests.swift") == Self.mutable)
    }

    /// The manifest is Swift, and rewriting it would change how the package
    /// builds rather than what it does.
    @Test("leaves Package.swift alone")
    func skipsManifest() throws {
        let (result, copy) = try inject([
            "Package.swift": Self.mutable,
            "Sources/A.swift": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { !$0.filePath.hasSuffix("Package.swift") })
        #expect(copy.read("Package.swift") == Self.mutable)
    }

    @Test("ignores files that are not Swift")
    func skipsNonSwift() throws {
        let (result, _) = try inject([
            "Sources/A.swift": Self.mutable,
            "Sources/notes.md": Self.mutable,
            "Sources/A.swift.bak": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { $0.filePath.hasSuffix("/A.swift") })
    }

    /// Dependencies are copied, because the build needs them, and left alone,
    /// because they are not the code under test.
    @Test("copies a dependency store without mutating it")
    func copiesButSkipsDependencies() throws {
        let (result, copy) = try inject([
            "Sources/A.swift": Self.mutable,
            ".build/checkouts/Other/B.swift": Self.mutable,
            "Pods/C.swift": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { $0.filePath.contains("/Sources/") })
        #expect(copy.read(".build/checkouts/Other/B.swift") == Self.mutable)
        #expect(copy.read("Pods/C.swift") == Self.mutable)
    }

    /// Build output is regenerable, so it is not copied at all.
    @Test("leaves build output out of the copy")
    func skipsBuildOutput() throws {
        let (result, copy) = try inject([
            "Sources/A.swift": Self.mutable,
            "build/Stale.swift": Self.mutable,
            "DerivedData/Old.swift": Self.mutable,
        ])

        #expect(result.mutants.allSatisfy { $0.filePath.contains("/Sources/") })
        #expect(copy.read("build/Stale.swift") == nil)
        #expect(copy.read("DerivedData/Old.swift") == nil)
    }

    // MARK: - bookkeeping

    @Test("counts files that had nothing to mutate")
    func countsUntouched() throws {
        let (result, _) = try inject([
            "Sources/A.swift": Self.mutable,
            "Sources/Empty.swift": "struct Empty { let value = 1 }",
            "Sources/AlsoEmpty.swift": "enum Nothing {}",
        ])

        #expect(result.untouched == 2)
    }

    @Test("narrows to the paths asked for")
    func include() throws {
        let (result, copy) = try inject([
            "Sources/Wanted.swift": Self.mutable,
            "Sources/Other.swift": Self.mutable,
        ], include: "Wanted")

        #expect(!result.mutants.isEmpty)
        #expect(result.mutants.allSatisfy { $0.filePath.hasSuffix("Wanted.swift") })
        #expect(copy.read("Sources/Other.swift") == Self.mutable)
    }

    /// Order is what makes a plan comparable between runs.
    @Test("returns mutants in a stable order")
    func stableOrder() throws {
        let files = ["C", "A", "B"].reduce(into: [String: String]()) {
            $0["Sources/\($1).swift"] = Self.mutable
        }

        // Compared by name: each run copies into its own temporary directory,
        // so the paths differ by a prefix that says nothing about order.
        let first = try inject(files).result.mutants.map(\.fileName)
        let second = try inject(files).result.mutants.map(\.fileName)

        #expect(first == second)
        #expect(first == ["A.swift", "B.swift", "C.swift"])
    }
}
