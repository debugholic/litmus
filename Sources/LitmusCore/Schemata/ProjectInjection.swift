import Foundation

/// Copies a project and writes every mutant into the copy.
///
/// The original is never touched. A run that is interrupted leaves the working
/// copy behind rather than a half-mutated source tree.
public struct ProjectInjection: Sendable {
    public struct Result: Sendable {
        public let workingCopy: URL
        public let mutants: [Mutant]
        /// Files that were read but produced nothing to mutate.
        public let untouched: Int
        /// Mutants dropped because no test reaches them.
        public let uncovered: Int
        /// Mutants dropped because the change did not touch them.
        public let unchanged: Int
    }

    /// Directories the build makes for itself, and can make again.
    static let notCopied: Set<String> = [
        ".git", "build", "DerivedData", "node_modules",
    ]

    /// Directories that are copied but never mutated.
    ///
    /// Dependency stores have to come along — `.build`, `Pods` and `Carthage`
    /// hold code the build needs and will not fetch again on its own, and
    /// leaving them out produced "no such module 'Lottie'" on a project whose
    /// packages live in `Tuist/.build`. None of it is the code under test, so
    /// none of it is worth changing.
    ///
    /// Test code is here for a different reason: mutating it would let the
    /// suite grade itself.
    static let notMutated: Set<String> = notCopied.union([
        ".build", ".swiftpm", "Pods", "Carthage", "Tests", "Test",
    ])

    public let injector: SchemataInjector
    public let include: String?
    /// What the suite reached, if it was measured. Mutants outside it are never
    /// written: they would survive whatever the code did, and each one costs a
    /// run to learn nothing.
    public let coverage: Coverage?
    /// The lines a change touched, if a range was given. Everything else keeps
    /// the verdict it had on the last run, so re-earning it costs time and
    /// tells nobody anything.
    public let changed: ChangedLines?

    public init(
        injector: SchemataInjector = SchemataInjector(),
        include: String? = nil,
        coverage: Coverage? = nil,
        changed: ChangedLines? = nil
    ) {
        self.injector = injector
        self.include = include
        self.coverage = coverage
        self.changed = changed
    }

    public func callAsFunction(
        project: URL,
        workingCopy: URL,
        progress: (String) -> Void = { _ in }
    ) throws -> Result {
        try copy(project, to: workingCopy)

        var mutants: [Mutant] = []
        var untouched = 0
        var uncovered = 0
        var unchanged = 0

        let files = try swiftFiles(in: workingCopy)

        // Coverage was measured on the original project, so its paths name the
        // original tree. Re-keying it onto the copy is what makes the lookup
        // below match anything at all.
        let coverage = coverage?.rebased(onto: files.map(\.path))
        let changed = changed?.rebased(onto: files.map(\.path))

        for file in files {
            if let include, !file.path.contains(include) { continue }

            let result = try injector(path: file.path)
            guard !result.mutants.isEmpty else {
                untouched += 1
                continue
            }

            // Filtered before the file is written, not after: a mutant no test
            // reaches would otherwise still be compiled in and still grow the
            // file, for a verdict that is known in advance.
            let touched = result.mutants.filter {
                changed?.includes(path: file.path, line: $0.line) ?? true
            }
            unchanged += result.mutants.count - touched.count

            let reachable = touched.filter {
                coverage?.reaches(path: file.path, line: $0.line) ?? true
            }
            uncovered += touched.count - reachable.count

            guard !reachable.isEmpty else {
                untouched += 1
                continue
            }

            try result.source.write(to: file, atomically: true, encoding: .utf8)
            mutants.append(contentsOf: reachable)
            progress("\(file.lastPathComponent): \(reachable.count)")
        }

        return Result(
            workingCopy: workingCopy,
            mutants: mutants,
            untouched: untouched,
            uncovered: uncovered,
            unchanged: unchanged
        )
    }

    /// Clones the project, then prunes what the build can make again.
    ///
    /// A clone rather than hardlinks. `rsync --link-dest` made every unchanged
    /// file in the copy the same inode as the original, so anything that
    /// wrote to one in place wrote to the other: a test driver appended to a
    /// test file in the copy landed in the user's project. A clone shares
    /// bytes until one side is written, then splits, which keeps the copy
    /// free and the original untouched. Across volumes `cp -c` falls back to
    /// an ordinary copy by itself.
    private func copy(_ project: URL, to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)

        let entries = try FileManager.default.contentsOfDirectory(atPath: project.path)
            .filter { !Self.notCopied.contains($0) }

        for entry in entries {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/cp")
            process.arguments = [
                "-c", "-R", "-p",
                project.appendingPathComponent(entry).path,
                destination.appendingPathComponent(entry).path,
            ]
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else {
                throw CopyFailure(description: "could not copy \(entry) into the working copy")
            }
        }

        try prune(destination)
    }

    /// Removes regenerable directories below the top level, such as an
    /// example app's node_modules.
    private func prune(_ root: URL) throws {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        else { return }

        var doomed: [URL] = []
        for case let url as URL in walker where Self.notCopied.contains(url.lastPathComponent) {
            doomed.append(url)
            walker.skipDescendants()
        }

        for url in doomed {
            try FileManager.default.removeItem(at: url)
        }
    }

    public struct CopyFailure: Error, CustomStringConvertible {
        public let description: String
    }

    private func swiftFiles(in root: URL) throws -> [URL] {
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }

        var files: [URL] = []

        for case let url as URL in walker {
            if Self.notMutated.contains(url.lastPathComponent) {
                walker.skipDescendants()
                continue
            }

            if url.pathExtension == "swift", url.lastPathComponent != "Package.swift" {
                files.append(url)
            }
        }

        return files.sorted { $0.path < $1.path }
    }
}
